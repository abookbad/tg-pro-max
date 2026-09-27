import AppKit
import SwiftUI
import UserNotifications

@main struct TGProMaxApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, UNUserNotificationCenterDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var monitor: Monitor!
    private var settingsWindow: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        monitor = Monitor(preview: CommandLine.arguments.contains("--render-preview") || CommandLine.arguments.contains("--render-previews"))
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "thermometer.medium", accessibilityDescription: "TG PRO MAX")
            button.imagePosition = .imageLeading
            button.title = " —"
            button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            button.target = self; button.action = #selector(toggle)
        }
        monitor.onReading = { [weak self] in self?.updateStatus() }
        monitor.showSettings = { [weak self] in self?.openSettings() }
        updateStatus()
        popover.behavior = .transient; popover.delegate = self
        if CommandLine.arguments.contains("--show") { toggle() }
        if CommandLine.arguments.contains("--settings") { openSettings() }
        if let index = CommandLine.arguments.firstIndex(of: "--render-previews"), CommandLine.arguments.count > index + 1 {
            let directory = CommandLine.arguments[index + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [self] in
                @MainActor func save<V: View>(_ view: V, _ name: String) {
                    let host = NSHostingView(rootView: view)
                    host.setFrameSize(host.fittingSize)
                    let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
                    window.contentView = host
                    host.layoutSubtreeIfNeeded()
                    if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
                    }
                    window.contentView = nil
                }
                monitor.preferences.overlay = true
                save(Dashboard(monitor: monitor), "dashboard-dark")
                monitor.preferences.appearance = .light
                monitor.preferences.compact = true
                monitor.preferences.unit = .fahrenheit
                save(Dashboard(monitor: monitor), "dashboard-light")
                for section in ["Appearance", "Dashboard", "Efficiency", "Alerts"] {
                    save(SettingsView(monitor: monitor, section: section), "settings-" + section.lowercased())
                }
                NSApplication.shared.terminate(nil)
            }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-preview"), CommandLine.arguments.count > index + 1 {
            let path = CommandLine.arguments[index + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [self] in
                let renderer = ImageRenderer(content: Dashboard(monitor: monitor).previewContent)
                renderer.scale = 2
                if let image = renderer.cgImage {
                    let bitmap = NSBitmapImageRep(cgImage: image)
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
                NSApplication.shared.terminate(nil)
            }
        }
    }
    private func updateStatus() {
        guard let button = statusItem.button else { return }
        let preferences = monitor.preferences
        let title = preferences.menuTitle(values: monitor.snapshot?.values ?? [:])
        let showIcon = preferences.menuIcon || preferences.menuMetric == .icon
        let displayTitle = title.isEmpty ? "" : (showIcon ? " " : "") + title
        let hottest = preferences.menuMetric.components.compactMap { monitor.snapshot?.values[$0] }.max()
        let warning = preferences.menuColor && hottest.map { $0 >= preferences.warningThreshold } == true
        let attributed = NSAttributedString(string: displayTitle, attributes: [
            .foregroundColor: warning ? NSColor.systemOrange : NSColor.labelColor,
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        ])
        if !button.attributedTitle.isEqual(to: attributed) { button.attributedTitle = attributed }
        if showIcon && button.image == nil { button.image = NSImage(systemSymbolName: "thermometer.medium", accessibilityDescription: "TG PRO MAX") }
        if !showIcon { button.image = nil }
        button.contentTintColor = warning ? .systemOrange : nil
        button.toolTip = "TG PRO MAX · Hottest mapped readings\nCPU: \(preferences.unit.format(monitor.snapshot?.values[.cpu])) · GPU: \(preferences.unit.format(monitor.snapshot?.values[.gpu]))"
    }
    private func openSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 530), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "TG PRO MAX Settings"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentViewController = NSHostingController(rootView: SettingsView(monitor: monitor))
            window.center()
            settingsWindow = window
        }
        monitor.refreshLogin()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) {
        settingsWindow?.contentViewController = nil
        settingsWindow = nil
    }
    @objc private func toggle() {
        if popover.isShown { popover.performClose(nil); return }
        guard let button = statusItem.button else { return }
        monitor.refreshLogin()
        popover.contentViewController = NSHostingController(rootView: Dashboard(monitor: monitor))
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func popoverDidClose(_ notification: Notification) {
        // Destroy the chart while closed: background work is sampling and a small status label only.
        popover.contentViewController = nil
    }
    func applicationWillTerminate(_ notification: Notification) { monitor.stop() }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
