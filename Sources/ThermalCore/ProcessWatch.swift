import Foundation

/// One process as the watcher sees it. `args`, `cwd` and `ports` are only filled for processes worth a closer look.
public struct ProcInfo: Sendable, Equatable {
    public var pid: Int32, ppid: Int32
    public var name: String
    public var start: Int64            // seconds since 1970; with pid it identifies the process across scans
    public var cpu: Double             // percent of one core since the previous scan
    public var path: String = ""
    public var args: [String] = []
    public var cwd: String?
    public var ports: [UInt16] = []
    public init(pid: Int32, ppid: Int32, name: String, start: Int64, cpu: Double = 0, path: String = "", args: [String] = [], cwd: String? = nil, ports: [UInt16] = []) {
        self.pid = pid; self.ppid = ppid; self.name = name; self.start = start; self.cpu = cpu
        self.path = path; self.args = args; self.cwd = cwd; self.ports = ports
    }
    public var started: Date { Date(timeIntervalSince1970: TimeInterval(start)) }
    var text: String { (args.isEmpty ? name : args.joined(separator: " ")).lowercased() }
}

public struct WatchSettings: Codable, Equatable, Sendable {
    public var enabled = true
    public var autoStop = true             // stop flagged dev servers without asking
    public var leftoverMinutes = 15.0      // grace before a dev server whose launcher is gone counts as left over
    public var maxAgeHours = 24.0          // 0 = never stop a dev server for age alone
    public var runawayCPU = 80.0           // percent of one core
    public var runawayMinutes = 10.0
    public var notify = true
    public var ai = true                   // explain runaway alerts with OpenAI when a key is available
    public static let defaultModel = "gpt-6-luna"
    public var model = WatchSettings.defaultModel
    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self), d = WatchSettings()
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? d.enabled
        autoStop = (try? c.decodeIfPresent(Bool.self, forKey: .autoStop)) ?? d.autoStop
        leftoverMinutes = (try? c.decodeIfPresent(Double.self, forKey: .leftoverMinutes)) ?? d.leftoverMinutes
        maxAgeHours = (try? c.decodeIfPresent(Double.self, forKey: .maxAgeHours)) ?? d.maxAgeHours
        runawayCPU = (try? c.decodeIfPresent(Double.self, forKey: .runawayCPU)) ?? d.runawayCPU
        runawayMinutes = (try? c.decodeIfPresent(Double.self, forKey: .runawayMinutes)) ?? d.runawayMinutes
        notify = (try? c.decodeIfPresent(Bool.self, forKey: .notify)) ?? d.notify
        ai = (try? c.decodeIfPresent(Bool.self, forKey: .ai)) ?? d.ai
        model = (try? c.decodeIfPresent(String.self, forKey: .model)) ?? d.model
        normalize()
    }
    public mutating func normalize() {
        if ![5.0, 15, 30, 60].contains(leftoverMinutes) { leftoverMinutes = 15 }
        if ![0.0, 6, 12, 24, 48].contains(maxAgeHours) { maxAgeHours = 24 }
        runawayCPU = runawayCPU.isFinite ? min(400, max(30, runawayCPU)) : 80
        if ![2.0, 5, 10, 30].contains(runawayMinutes) { runawayMinutes = 10 }
        // Empty, or still on the old default (gpt-5-mini) → current default.
        if model.trimmingCharacters(in: .whitespaces).isEmpty || model == "gpt-5-mini" { model = WatchSettings.defaultModel }
    }
}

public struct WatchItem: Identifiable, Sendable, Equatable {
    public enum Flag: String, Sendable, CaseIterable { case runaway = "Runaway CPU", leftover = "Launcher gone", stale = "Running too long" }
    public var id: String
    public var pids: [Int32]                // stop order: deepest children first, root last
    public var starts: [Int32: Int64]       // checked again right before signalling (pid reuse)
    public var title: String                // "IMSA Website · Next.js server (test)"
    public var detail: String               // "help-desk worktree · :3019 · up 6d 15h"
    public var cpu: Double
    public var started: Date
    public var isDevServer: Bool
    public var flags: [Flag]
    public var context: String              // command lines + folder, for the AI explanation
}

/// Recognizes dev servers from their command lines.
public enum DevKind {
    /// Tools that are never dev servers even though they run on node/python (editors, agents, MCP servers).
    static let excluded = ["claude", "@anthropic-ai", "codex", "cursor", ".vscode", "mcp", "tsserver", "language-server", "eslint", "prettier", "copilot"]
    static let rules: [(label: String, any: [String])] = [
        ("Watcher", ["nodemon", "tsx watch", "ts-node-dev", "node --watch", "vitest", "jest --watch"]),   // before Vite: "vitest"
        ("Next.js", ["next-server", "next dev", "next start", "/next/dist/bin/next", "next/dist/server"]),
        ("Vite", ["/vite ", "/vite\n", "vite/bin", " vite dev", " vite --", "/.bin/vite"]),
        ("Expo", ["expo start", "expo/bin"]),
        ("Astro", ["astro dev"]),
        ("Nuxt", ["nuxt dev", "nuxi dev"]),
        ("Remix", ["remix dev", "remix vite:dev"]),
        ("Storybook", ["storybook dev", "start-storybook"]),
        ("Webpack", ["webpack serve", "webpack-dev-server"]),
        ("React", ["react-scripts start"]),
        ("Wrangler", ["wrangler dev"]),
        ("Vercel", ["vercel dev"]),
        ("Convex", ["convex dev"]),
        ("Turbo", ["turbo dev", "turbo run dev"]),
        ("Django", ["manage.py runserver"]),
        ("Flask", ["flask run"]),
        ("Uvicorn", ["uvicorn "]),
        ("Rails", ["rails server", "rails s ", "bin/rails s"])
    ]
    /// Excluded tools are matched with folder names that merely contain those words (CursorProjects, .claude/worktrees) removed.
    static func isExcluded(_ text: String) -> Bool {
        let t = text.lowercased().replacingOccurrences(of: "/.claude/", with: "/").replacingOccurrences(of: "cursorprojects", with: "")
        return excluded.contains(where: t.contains)
    }
    /// The framework a command line runs, or nil when it is not a dev server.
    public static func framework(_ text: String) -> String? {
        let t = text.lowercased() + "\n"
        guard !isExcluded(t) else { return nil }
        return rules.first { $0.any.contains(where: t.contains) }?.label
    }
    /// "Next.js dev server", "Next.js server (test)", "Watcher (test)".
    public static func label(_ text: String) -> String? {
        guard let f = framework(text) else { return nil }
        let t = text.lowercased()
        var name: String
        switch f {
        case "Watcher": name = t.contains("vitest") || t.contains("jest") ? "test watcher" : "file watcher"
        case "Next.js": name = t.contains("next dev") || t.contains("next-dev") || (t.contains(" dev") && !t.contains(" start")) ? "Next.js dev server" : "Next.js server"
        case "Django", "Flask", "Uvicorn", "Rails": name = "\(f) server"
        default: name = "\(f) dev server"
        }
        if f == "Watcher" { name = name.prefix(1).uppercased() + name.dropFirst() }
        let test = [".env.test", "start:test", "test:e2e", "--mode test", "playwright", "e2e"].contains(where: t.contains)
        return test && f != "Watcher" ? name + " (test)" : name
    }
    /// `--port 3019`, `--port=3019`, `-p 3019`.
    public static func port(_ args: [String]) -> UInt16? {
        let tokens = args.flatMap { $0.split(separator: " ").map(String.init) }
        for (i, t) in tokens.enumerated() {
            if t.hasPrefix("--port="), let p = UInt16(t.dropFirst(7)), p > 0 { return p }
            if (t == "--port" || t == "-p" || t == "--listen"), i + 1 < tokens.count, let p = UInt16(tokens[i + 1]), p > 0 { return p }
        }
        return nil
    }
}

/// Turns a folder into a readable project name: `…/imsa-website/.claude/worktrees/help-desk` → ("IMSA Website", "help-desk").
public enum ProjectName {
    static let acronyms: Set<String> = ["imsa", "nhs", "erp", "adw", "ugc", "mrp", "api", "ai", "ui", "ios", "mm", "sjb", "hmf", "ir", "tg", "pss", "oci", "crm", "cms", "sms", "bi", "db", "mcp", "wms", "ux", "qa"]
    public static func pretty(_ dir: String) -> String {
        dir.split(whereSeparator: { "-_. ".contains($0) }).map { word -> String in
            let w = word.lowercased()
            if acronyms.contains(w) || (w.count <= 4 && !w.contains(where: "aeiouy0123456789".contains)) { return w.uppercased() }
            if w.first?.isNumber == true || (w.first == "v" && w.dropFirst().allSatisfy(\.isNumber) && w.count > 1) { return w }
            return w.prefix(1).uppercased() + w.dropFirst()
        }.joined(separator: " ")
    }
    /// - Parameter root: finds the project folder that contains `path` (nearest folder with .git / package.json).
    public static func parse(_ path: String, home: String, root: (String) -> String?) -> (project: String, worktree: String?)? {
        guard path.hasPrefix(home + "/"), path != home else { return nil }
        if let r = path.range(of: "/.claude/worktrees/") {
            let repo = String(path[..<r.lowerBound])
            let tree = path[r.upperBound...].split(separator: "/").first.map(String.init)
            return (pretty((repo as NSString).lastPathComponent), tree)
        }
        let base = root(path) ?? path
        guard base != home else { return nil }
        return (pretty((base as NSString).lastPathComponent), nil)
    }
}

public enum Age {
    public static func short(_ seconds: TimeInterval) -> String {
        let m = Int(max(0, seconds) / 60), h = m / 60, d = h / 24
        if d > 0 { return "\(d)d \(h % 24)h" }
        if h > 0 { return "\(h)h \(m % 60)m" }
        return "\(max(m, 1))m"
    }
}

/// Groups processes into dev-server trees and single heavy processes, and decides which are flagged.
public struct ProcessWatch: Sendable {
    public private(set) var highSince: [String: Date] = [:]
    public init() {}
    static let runtimes: Set<String> = ["node", "bun", "deno", "python", "python3", "Python", "ruby", "php", "npm", "npx", "pnpm", "yarn", "turbo", "uvicorn", "gunicorn", "next-server"]
    static let shells: Set<String> = ["sh", "bash", "zsh", "dash"]

    static func isRuntime(_ p: ProcInfo) -> Bool {
        let t = p.text
        if DevKind.isExcluded(t) { return false }
        return runtimes.contains(p.name) || p.name.hasPrefix("python") || p.name.hasPrefix("next-") || DevKind.framework(t) != nil
    }

    public mutating func evaluate(_ procs: [ProcInfo], now: Date, settings: WatchSettings, home: String, root: (String) -> String?) -> [WatchItem] {
        let byPid = Dictionary(procs.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var children: [Int32: [Int32]] = [:]
        for p in procs { children[p.ppid, default: []].append(p.pid) }

        // 1. Dev servers: climb from each recognised process to the topmost launcher (npm → sh -c → node …).
        var roots: [Int32] = []
        for p in procs where DevKind.framework(p.text) != nil {
            var top = p
            while let parent = byPid[top.ppid], parent.pid > 1 {
                let viaShell = Self.shells.contains(parent.name) && byPid[parent.ppid].map(Self.isRuntime) == true
                guard Self.isRuntime(parent) || viaShell else { break }
                top = parent
            }
            if !roots.contains(top.pid) { roots.append(top.pid) }
        }
        let candidates = roots
        roots.removeAll { r in candidates.contains { other in other != r && Self.isAncestor(other, of: r, byPid) } }

        var items: [WatchItem] = []
        var claimed = Set<Int32>()
        for rootPid in roots {
            guard let rootProc = byPid[rootPid] else { continue }
            var members: [ProcInfo] = []
            var order: [Int32] = []
            func walk(_ pid: Int32) {
                guard let p = byPid[pid], !claimed.contains(pid) else { return }
                claimed.insert(pid); members.append(p)
                for c in children[pid] ?? [] { walk(c) }
                order.append(pid)      // post-order: children before parents
            }
            walk(rootPid)
            let text = members.map(\.text).joined(separator: "\n")
            let dev = members.first { DevKind.framework($0.text) != nil }
            let label = DevKind.label(text) ?? "Dev server"
            let folder = dev?.cwd ?? rootProc.cwd ?? members.compactMap(\.cwd).first
            let project = folder.flatMap { ProjectName.parse($0, home: home, root: root) }
            let port = DevKind.port(members.flatMap(\.args)) ?? members.flatMap(\.ports).filter { $0 > 0 && $0 < 49152 }.min()
            let launcherGone = rootProc.ppid == 1 || byPid[rootProc.ppid].map { Self.shells.contains($0.name) && $0.ppid == 1 } == true
            let age = now.timeIntervalSince(rootProc.started)
            var detail: [String] = []
            if let tree = project?.worktree { detail.append("\(tree) worktree") }
            if let port { detail.append(":\(port)") }
            detail.append("up \(Age.short(age))")
            var flags: [WatchItem.Flag] = []
            if launcherGone && age >= settings.leftoverMinutes * 60 { flags.append(.leftover) }
            else if launcherGone { detail.append("launcher gone") }      // not flagged yet: still in the grace period
            if settings.maxAgeHours > 0 && age >= settings.maxAgeHours * 3600 { flags.append(.stale) }
            items.append(WatchItem(
                id: "dev-\(rootPid)-\(rootProc.start)", pids: order, starts: Dictionary(members.map { ($0.pid, $0.start) }, uniquingKeysWith: { a, _ in a }),
                title: [project?.project, label].compactMap { $0 }.joined(separator: " · "), detail: detail.joined(separator: " · "),
                cpu: members.reduce(0) { $0 + $1.cpu }, started: rootProc.started, isDevServer: true, flags: flags,
                context: "Folder: \(folder ?? "unknown")\nLauncher still running: \(!launcherGone)\nCommands:\n" + members.map { "- " + ($0.args.isEmpty ? $0.name : $0.args.joined(separator: " ")) }.joined(separator: "\n")))
        }

        // 2. Anything else that is busy right now.
        for p in procs where !claimed.contains(p.pid) && p.cpu >= 20 {
            let app = Self.appName(p.path)
            var title = app.map { $0 == p.name ? $0 : "\($0) · \(p.name)" } ?? p.name
            if Self.isRuntime(p), let script = p.args.dropFirst().first(where: { !$0.hasPrefix("-") }) {
                title = "\(p.name) \((script as NSString).lastPathComponent)"
                if let project = p.cwd.flatMap({ ProjectName.parse($0, home: home, root: root) }) { title = "\(project.project) · " + title }
            }
            items.append(WatchItem(
                id: "p-\(p.pid)-\(p.start)", pids: [p.pid], starts: [p.pid: p.start], title: title, detail: "up \(Age.short(now.timeIntervalSince(p.started)))",
                cpu: p.cpu, started: p.started, isDevServer: false, flags: [],
                context: "Executable: \(p.path)\nCommand: \(p.args.joined(separator: " "))\nFolder: \(p.cwd ?? "unknown")"))
        }

        // 3. Runaway: sustained CPU, tracked across scans.
        let live = Set(items.map(\.id))
        highSince = highSince.filter { live.contains($0.key) }
        for i in items.indices {
            if items[i].cpu >= settings.runawayCPU { highSince[items[i].id] = highSince[items[i].id] ?? now } else { highSince[items[i].id] = nil }
            if let since = highSince[items[i].id], now.timeIntervalSince(since) >= settings.runawayMinutes * 60 { items[i].flags.insert(.runaway, at: 0) }
        }
        return items.sorted { ($0.flags.isEmpty ? 1 : 0, $0.isDevServer ? 0 : 1, -$0.cpu) < ($1.flags.isEmpty ? 1 : 0, $1.isDevServer ? 0 : 1, -$1.cpu) }
    }

    /// Flagged dev servers stop on their own; other processes are only reported.
    public static func shouldAutoStop(_ item: WatchItem, settings: WatchSettings) -> Bool {
        settings.autoStop && item.isDevServer && !item.flags.isEmpty
    }

    static func isAncestor(_ a: Int32, of b: Int32, _ byPid: [Int32: ProcInfo]) -> Bool {
        var cur = byPid[b]?.ppid
        while let c = cur, c > 1 { if c == a { return true }; cur = byPid[c]?.ppid }
        return false
    }
    /// Outermost `.app` in an executable path: Spotify Helper (Renderer) → "Spotify".
    static func appName(_ path: String) -> String? {
        guard let r = path.range(of: ".app/") else { return nil }
        return (String(path[..<r.lowerBound]) as NSString).lastPathComponent
    }
}

/// Strips secrets from command lines before they leave the Mac.
public enum Redact {
    public static func text(_ s: String) -> String {
        var out = s
        let patterns = [
            #"(?i)(key|token|secret|password|passwd|auth|bearer)([=: ]+)\S+"#,
            #"sk-[A-Za-z0-9_\-]{8,}"#,
            #"[A-Za-z0-9+/_\-]{32,}={0,2}"#
        ]
        for p in patterns {
            out = out.replacingOccurrences(of: p, with: p.hasPrefix("(?i)") ? "$1$2<redacted>" : "<redacted>", options: .regularExpression)
        }
        return out
    }
}
