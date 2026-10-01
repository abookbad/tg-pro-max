import AppKit
import Combine
import ServiceManagement
import UserNotifications
import ThermalCore
import IOKit.ps

struct Snapshot: Sendable {
    let date: Date
    let readings: [SensorReading]
    let values: [Component: Double]
    let pressure: Int
    let status: String
    let interval: TimeInterval
}

final class Sampler {
    private let queue = DispatchQueue(label: "app.tgpromax.sensors", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var reader: SMCReader?
    private var ticks = 0
    private var interval: TimeInterval = 1
    let isM5: Bool
    init(isM5: Bool) { self.isM5 = isM5 }
    func start(interval: TimeInterval, deliver: @escaping (Snapshot) -> Void) {
        queue.async { [self] in
            timer?.cancel()
            self.interval = interval
            reader = SMCReader()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(100))
            timer.setEventHandler { [weak self] in self?.sample(deliver: deliver) }
            self.timer = timer
            timer.resume()
        }
    }
    func setInterval(_ interval: TimeInterval) {
        queue.async {
            self.interval = interval
            self.timer?.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(100))
        }
    }
    func stop() { queue.async { self.timer?.cancel(); self.timer = nil; self.reader = nil } }
    private func sample(deliver: (Snapshot) -> Void) {
        guard let reader else { return }
        let selected: Set<String>? = isM5 ? Set(Component.m5CPU + Component.m5GPU + ["TB1T", "TB2T", "TH0x", "F0Ac", "F1Ac"]) : nil
        let readings = reader.read(only: selected).filter { Component.group($0.key, isM5: isM5) != nil || $0.key.hasPrefix("F") }
        var values: [Component: Double] = [:]
        for r in readings {
            if let c = Component.group(r.key, isM5: isM5) { values[c] = max(values[c] ?? r.value, r.value) }
        }
        deliver(Snapshot(date: Date(), readings: readings, values: values,
                         pressure: ProcessInfo.processInfo.thermalState.rawValue, status: reader.status, interval: interval))
        ticks += 1
        if readings.isEmpty && ticks % 30 == 0 { reader.reconnect() }
    }
}

@MainActor final class Monitor: ObservableObject {
    @Published var snapshot: Snapshot?
    @Published var history = History()
    @Published var selected: Component = .cpu
    @Published var message: String?
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    @Published var alertsEnabled: Bool
    @Published var threshold: Double
    @Published var preferences: Preferences {
        didSet {
            if let data = try? JSONEncoder().encode(preferences) { defaults?.set(data, forKey: "preferences.v1") }
            if preferences.interval != oldValue.interval || preferences.batteryInterval != oldValue.batteryInterval || preferences.slowerOnBattery != oldValue.slowerOnBattery {
                gate.interrupt(); sampler.setInterval(effectiveInterval)
            }
            if preferences.sustainSeconds != oldValue.sustainSeconds || preferences.cooldownSeconds != oldValue.cooldownSeconds { gate.reset() }
            if preferences.hiddenRows.contains(selected.rawValue), let first = visibleComponents.first { selected = first }
            onReading?()
        }
    }
    @Published private(set) var onBattery = false
    private var powerSource: CFRunLoopSource?
    private var sleeping = false
    private var notificationRequestID = 0
    private let defaults: UserDefaults?
    var effectiveInterval: TimeInterval { preferences.effectiveInterval(onBattery: onBattery) }
    var visibleComponents: [Component] {
        preferences.rowOrder.compactMap(Component.init(rawValue:)).filter { !preferences.hiddenRows.contains($0.rawValue) }
    }
    let chip: String
    let sampler: Sampler
    let processes: ProcessWatcher
    private var gate = AlertGate()
    private var observers: [NSObjectProtocol] = []
    var showSettings: (() -> Void)?
    var onReading: (() -> Void)?
    init(preview: Bool = false) {
        defaults = preview ? nil : .standard
        alertsEnabled = defaults?.bool(forKey: "alerts") ?? false
        threshold = defaults?.object(forKey: "threshold") as? Double ?? 90
        var saved = defaults?.data(forKey: "preferences.v1").flatMap { try? JSONDecoder().decode(Preferences.self, from: $0) } ?? Preferences()
        saved.normalize()
        preferences = saved
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var bytes = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0)
        chip = String(cString: bytes)
        sampler = Sampler(isM5: chip.contains("M5"))
        processes = ProcessWatcher(preview: preview)
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.sleeping = true; self.gate.interrupt()
                self.sampler.stop(); self.processes.stop(); self.snapshot = nil; self.onReading?()
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sleeping = false; self?.refreshPower(); self?.start(); self?.processes.start() }
        })
        if let first = visibleComponents.first { selected = first }
        refreshPower()
        powerSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<Monitor>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor [weak monitor] in monitor?.refreshPower() }
        }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue()
        if let powerSource { CFRunLoopAddSource(CFRunLoopGetMain(), powerSource, .commonModes) }
        start()
    }
    func refreshPower() {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return }
        let battery = source as String == kIOPSBatteryPowerValue
        if battery != onBattery {
            onBattery = battery; gate.interrupt(); sampler.setInterval(effectiveInterval); processes.onBattery = battery
        }
    }
    func stop() {
        sampler.stop(); processes.stop()
        if let powerSource { CFRunLoopSourceInvalidate(powerSource) }
        powerSource = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers = []
    }
    func start() {
        sampler.start(interval: effectiveInterval) { [weak self] sample in
            Task { @MainActor in self?.receive(sample) }
        }
    }
    private func receive(_ sample: Snapshot) {
        guard !sleeping else { return }
        snapshot = sample
        history.append(Sample(date: sample.date, values: sample.values, interval: sample.interval))
        onReading?()
        if alertsEnabled && gate.shouldAlert(value: sample.values[.cpu], threshold: threshold, now: sample.date,
                                             sustain: preferences.sustainSeconds, cooldown: preferences.cooldownSeconds,
                                             maximumGap: sample.interval * 1.5 + 0.5) {
            let content = UNMutableNotificationContent()
            content.title = "TG PRO MAX · CPU temperature"
            content.body = "CPU: \(preferences.unit.format(sample.values[.cpu])). Above \(preferences.unit.format(threshold)) for at least \(Int(preferences.sustainSeconds)) seconds."
            content.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { [weak self] error in
                if let error { Task { @MainActor in self?.message = "Notification failed: \(error.localizedDescription)" } }
            }
        }
    }
    func setThreshold(_ value: Double) {
        threshold = min(110, max(40, value)); gate.reset()
        defaults?.set(threshold, forKey: "threshold")
    }
    func setAlerts(_ enabled: Bool) {
        guard defaults != nil else { return }
        notificationRequestID += 1
        let request = notificationRequestID
        gate.reset()
        alertsEnabled = false; defaults?.set(false, forKey: "alerts")
        guard enabled else { return }
        Task {
            do {
                let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                guard request == notificationRequestID else { return }
                alertsEnabled = granted; defaults?.set(granted, forKey: "alerts")
                if !granted { message = "Notifications are disabled. Allow TG PRO MAX in System Settings → Notifications." }
            } catch {
                guard request == notificationRequestID else { return }
                message = error.localizedDescription
            }
        }
    }
    func setLogin(_ enabled: Bool) {
        guard defaults != nil else { return }
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            refreshLogin()
            if SMAppService.mainApp.status == .requiresApproval {
                message = "Allow TG PRO MAX in System Settings → General → Login Items."
                SMAppService.openSystemSettingsLoginItems()
            }
        } catch { refreshLogin(); message = "Launch at login: \(error.localizedDescription)" }
    }
    func refreshLogin() { loginEnabled = SMAppService.mainApp.status == .enabled }
    var pressure: String {
        switch snapshot?.pressure { case 0: return "Nominal"; case 1: return "Fair"; case 2: return "Serious"; case 3: return "Critical"; default: return "Unavailable" }
    }
}
