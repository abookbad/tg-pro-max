import Foundation
import Security
import UserNotifications
import ThermalCore

struct StoppedEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    let date: Date
    let title: String
    let reason: String
}

/// Watches for runaway processes and left-over dev servers; stops flagged dev servers on its own.
@MainActor final class ProcessWatcher: ObservableObject {
    @Published private(set) var items: [WatchItem] = []
    @Published private(set) var stopped: [StoppedEntry] = []
    @Published private(set) var explanations: [String: String] = [:]
    @Published private(set) var explaining: Set<String> = []
    @Published private(set) var stopping: Set<String> = []
    @Published var settings: WatchSettings {
        didSet {
            if let data = try? JSONEncoder().encode(settings) { defaults?.set(data, forKey: "processWatch.v1") }
            if settings.enabled != oldValue.enabled { settings.enabled ? start() : stop() }
            if settings.notify && !oldValue.notify { requestNotifications() }
        }
    }
    var onBattery = false { didSet { if onBattery != oldValue { reschedule() } } }
    var interval: TimeInterval { onBattery ? 30 : 15 }

    private let queue = DispatchQueue(label: "app.tgpromax.processes", qos: .utility)
    private let table = ProcessTable()             // touched on `queue` only
    private var watch = ProcessWatch()
    private var timer: DispatchSourceTimer?
    private var alerted: [String: Date] = [:]
    private let defaults: UserDefaults?
    private let home = NSHomeDirectory()

    init(preview: Bool) {
        defaults = preview ? nil : .standard
        var saved = defaults?.data(forKey: "processWatch.v1").flatMap { try? JSONDecoder().decode(WatchSettings.self, from: $0) } ?? WatchSettings()
        saved.normalize()
        settings = saved
        stopped = defaults?.data(forKey: "processWatch.stopped").flatMap { try? JSONDecoder().decode([StoppedEntry].self, from: $0) } ?? []
        if settings.enabled { start() }
        if settings.notify && !preview { requestNotifications() }
    }

    func start() {
        guard settings.enabled, timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: interval, leeway: .seconds(2))
        t.setEventHandler { [weak self, table] in
            let procs = table.scan()
            Task { @MainActor in self?.receive(procs) }
        }
        timer = t; t.resume()
    }
    func stop() { timer?.cancel(); timer = nil }
    private func reschedule() { timer?.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(2)) }
    func refreshSoon() { queue.asyncAfter(deadline: .now() + 0.3) { [weak self, table] in let p = table.scan(); Task { @MainActor in self?.receive(p) } } }

    private func receive(_ procs: [ProcInfo]) {
        guard settings.enabled else { return }
        items = watch.evaluate(procs, now: Date(), settings: settings, home: home, root: ProjectRoot.find)
        for item in items where !item.flags.isEmpty && !stopping.contains(item.id) {
            if defaults != nil, ProcessWatch.shouldAutoStop(item, settings: settings) {   // previews never signal
                kill(item, reason: item.flags.map(\.rawValue).joined(separator: ", "), automatic: true)
            } else if item.flags.contains(.runaway), alerted[item.id].map({ Date().timeIntervalSince($0) > 3600 }) ?? true {
                alerted[item.id] = Date()
                Task { await alertRunaway(item) }
            }
        }
    }

    /// SIGTERM the whole tree (children first), then SIGKILL whatever is still there after 3 seconds.
    func kill(_ item: WatchItem, reason: String = "Stopped by you", automatic: Bool = false) {
        stopping.insert(item.id)
        let targets = item.pids.compactMap { pid in item.starts[pid].map { (pid, $0) } }
        let queue = queue
        queue.async { [weak self] in
            for (pid, start) in targets { ProcessTable.signal(pid, start: start, SIGTERM) }
            queue.asyncAfter(deadline: .now() + 3) { [weak self] in
                for (pid, start) in targets where ProcessTable.isAlive(pid, start: start) { ProcessTable.signal(pid, start: start, SIGKILL) }
                Task { @MainActor in
                    guard let self else { return }
                    self.stopping.remove(item.id)
                    self.log(StoppedEntry(date: Date(), title: item.title, reason: reason + " · \(item.detail)"))
                    if automatic { self.notify("Stopped \(item.title)", "\(reason). It had been \(item.detail).") }
                    self.refreshSoon()
                }
            }
        }
    }

    private func log(_ entry: StoppedEntry) {
        stopped = Array(([entry] + stopped).prefix(20))
        if let data = try? JSONEncoder().encode(stopped) { defaults?.set(data, forKey: "processWatch.stopped") }
    }
    func clearLog() { stopped = []; defaults?.removeObject(forKey: "processWatch.stopped") }

    private func alertRunaway(_ item: WatchItem) async {
        var body = "\(Int(item.cpu.rounded()))% CPU for \(Int(settings.runawayMinutes))+ minutes · \(item.detail)."
        if settings.ai, AIExplainer.hasKey, let why = try? await AIExplainer.explain(item, model: settings.model) {
            explanations[item.id] = why
            body += " " + why
        }
        notify("\(item.title) is burning CPU", body)
    }

    func explain(_ item: WatchItem) {
        guard !explaining.contains(item.id) else { return }
        explaining.insert(item.id)
        Task {
            defer { explaining.remove(item.id) }
            do { explanations[item.id] = try await AIExplainer.explain(item, model: settings.model) }
            catch { explanations[item.id] = error.localizedDescription }
        }
    }

    private func requestNotifications() {
        guard defaults != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
    private func notify(_ title: String, _ body: String) {
        guard settings.notify, defaults != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body; content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

/// On-demand OpenAI explanations. Only called when you press Explain or a runaway alert fires; command lines are redacted first.
enum AIExplainer {
    struct Failure: LocalizedError { let errorDescription: String? }
    static let keychainService = "local.tgpromax.openai"

    /// Key order: Settings (Keychain) → OPENAI_API_KEY → ~/.codex/secrets/openai.env.
    static var key: String? {
        if let k = keychainKey, !k.isEmpty { return k }
        if let k = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], k.hasPrefix("sk-") { return k }
        let file = NSHomeDirectory() + "/.codex/secrets/openai.env"
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            let parts = line.replacingOccurrences(of: "export ", with: "").split(separator: "=", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "OPENAI_API_KEY" {
                return parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            }
        }
        return nil
    }
    static var hasKey: Bool { key?.isEmpty == false }
    static var keySource: String {
        if keychainKey?.isEmpty == false { return "Saved in Keychain" }
        if ProcessInfo.processInfo.environment["OPENAI_API_KEY"]?.hasPrefix("sk-") == true { return "From OPENAI_API_KEY" }
        if hasKey { return "From ~/.codex/secrets/openai.env" }
        return "No key found"
    }

    static var keychainKey: String? {
        var out: CFTypeRef?
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService, kSecReturnData as String: true]
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    static func saveKey(_ key: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService]
        SecItemDelete(base as CFDictionary)
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }
        var add = base; add[kSecValueData as String] = Data(k.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    static func explain(_ item: WatchItem, model: String) async throws -> String {
        guard let key else { throw Failure(errorDescription: "Add an OpenAI key in Settings → Processes.") }
        let facts = """
        Name shown to the user: \(item.title)
        Details: \(item.detail)
        CPU now: \(Int(item.cpu.rounded()))% of one core
        Flags: \(item.flags.map(\.rawValue).joined(separator: ", "))
        \(Redact.text(String(item.context.prefix(2500))))
        """
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": "You explain macOS processes inside a menu-bar monitor for a developer. Reply in at most two short sentences, plain words: what it is (and which project, if known), and whether it is safe to stop."],
                ["role": "user", "content": facts]
            ]
        ]
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"; request.timeoutInterval = 20
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let message = (json?["error"] as? [String: Any])?["message"] as? String ?? "HTTP \(http.statusCode)"
            throw Failure(errorDescription: "OpenAI: \(message)")
        }
        let text = ((json?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { throw Failure(errorDescription: "OpenAI returned no text.") }
        return text
    }
}
