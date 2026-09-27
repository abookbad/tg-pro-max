import SwiftUI
import ThermalCore

extension Tint {
    var color: Color {
        switch self { case .mint: return Color(red: 0.35, green: 0.9, blue: 0.73); case .blue: return .blue; case .purple: return .purple; case .orange: return .orange }
    }
}
extension Appearance {
    var scheme: ColorScheme? { switch self { case .system: return nil; case .dark: return .dark; case .light: return .light } }
}

struct SettingsView: View {
    @ObservedObject var monitor: Monitor
    @Environment(\.colorScheme) private var systemScheme
    @State private var tab = "Appearance"
    init(monitor: Monitor, section: String = "Appearance") {
        self.monitor = monitor
        _tab = State(initialValue: section)
    }
    private let tabs = ["Appearance", "Dashboard", "Efficiency", "Alerts"]
    func binding<Value>(_ key: WritableKeyPath<Preferences, Value>) -> Binding<Value> {
        Binding(get: { monitor.preferences[keyPath: key] }, set: { monitor.preferences[keyPath: key] = $0 })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Make it yours").font(.title2.bold())
                Spacer()
                Text("TG PRO MAX").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Picker("Settings section", selection: $tab) { ForEach(tabs, id: \.self) { Text($0) } }.pickerStyle(.segmented).labelsHidden()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch tab {
                    case "Dashboard": dashboard
                    case "Efficiency": efficiency
                    case "Alerts": alerts
                    default: appearance
                    }
                    if let message = monitor.message { Text(message).foregroundStyle(.orange).font(.caption) }
                }.padding(2)
            }
            Divider()
            Toggle("Launch at login", isOn: Binding(get: { monitor.loginEnabled }, set: monitor.setLogin))
        }
        .padding(24).frame(width: 480, height: 530)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, monitor.preferences.appearance.scheme ?? systemScheme)
        .tint(monitor.preferences.tint.color)
        .preferredColorScheme(monitor.preferences.appearance.scheme)
        .onAppear { monitor.refreshLogin() }
    }
    private var appearance: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("MENU BAR").font(.caption.bold()).foregroundStyle(.secondary)
            Picker("Display", selection: binding(\.menuMetric)) { ForEach(MenuMetric.allCases) { Text($0.rawValue).tag($0) } }
            Toggle("Show thermometer icon", isOn: binding(\.menuIcon)).disabled(monitor.preferences.menuMetric == .icon)
            Toggle("Show one decimal place", isOn: binding(\.menuDecimals)).disabled(monitor.preferences.menuMetric == .icon)
            Toggle("Color readings above warning temperature", isOn: binding(\.menuColor))
            HStack {
                Text("Warning temperature")
                Slider(value: binding(\.warningThreshold), in: 40...110, step: 1)
                Text(monitor.preferences.unit.format(monitor.preferences.warningThreshold, decimals: false)).monospacedDigit().frame(width: 58)
            }.disabled(!monitor.preferences.menuColor)
            Text("Color follows the hottest displayed component. It does not change alert settings.").font(.caption).foregroundStyle(.secondary)
            Divider()
            Picker("Temperature unit", selection: binding(\.unit)) { ForEach(TemperatureUnit.allCases) { Text($0.rawValue).tag($0) } }
            Picker("Theme", selection: binding(\.appearance)) { ForEach(Appearance.allCases) { Text($0.rawValue).tag($0) } }
            Picker("Accent", selection: binding(\.tint)) { ForEach(Tint.allCases) { Text($0.rawValue).tag($0) } }
        }
    }
    private var dashboard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Compact layout", isOn: binding(\.compact))
            Toggle("Show temperature graph", isOn: binding(\.showGraph))
            Toggle("Overlay CPU and GPU", isOn: binding(\.overlay)).disabled(!monitor.preferences.showGraph)
            Text("CHOOSE AND REORDER ROWS").font(.caption.bold()).foregroundStyle(.secondary)
            ForEach(Array(monitor.preferences.rowOrder.enumerated()), id: \.element) { index, id in
                HStack {
                    Toggle(rowName(id), isOn: Binding(get: { !monitor.preferences.hiddenRows.contains(id) }, set: { shown in
                        if shown { monitor.preferences.hiddenRows.remove(id) } else { monitor.preferences.hiddenRows.insert(id) }
                    })).toggleStyle(.checkbox)
                    Spacer()
                    Button { monitor.preferences.moveRow(id, by: -1) } label: { Image(systemName: "arrow.up") }
                        .disabled(index == 0).help("Move \(rowName(id)) up")
                    Button { monitor.preferences.moveRow(id, by: 1) } label: { Image(systemName: "arrow.down") }
                        .disabled(index == monitor.preferences.rowOrder.count - 1).help("Move \(rowName(id)) down")
                }
            }
            Text("Unavailable sensors stay hidden. Hiding a row does not disable monitoring or CPU alerts.").font(.caption).foregroundStyle(.secondary)
            Button("Reset row layout") { monitor.preferences.rowOrder = Preferences().rowOrder; monitor.preferences.hiddenRows = [] }
        }
    }
    private var efficiency: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Sampling interval", selection: binding(\.interval)) { ForEach([1.0, 2, 5, 10], id: \.self) { Text("\(Int($0)) seconds").tag($0) } }
            Toggle("Sample less often on battery", isOn: binding(\.slowerOnBattery))
            Picker("Battery interval", selection: binding(\.batteryInterval)) { ForEach([1.0, 2, 5, 10], id: \.self) { Text("\(Int($0)) seconds").tag($0) } }.disabled(!monitor.preferences.slowerOnBattery)
            Label("Currently every \(Int(monitor.effectiveInterval)) seconds · \(monitor.onBattery ? "Battery" : "Power adapter")", systemImage: monitor.onBattery ? "battery.75percent" : "powerplug")
                .font(.callout).foregroundStyle(.secondary)
            Text("Battery mode uses the slower of the two intervals. Longer intervals reduce sensor reads and UI updates, but can miss brief temperature spikes.").font(.callout).foregroundStyle(.secondary)
            Divider()
            Text("History is limited to 10 minutes and 600 samples in memory. Sampling pauses during sleep. The popup graph is released when closed.").font(.callout).foregroundStyle(.secondary)
        }
    }
    private var alerts: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("CPU temperature notifications", isOn: Binding(get: { monitor.alertsEnabled }, set: monitor.setAlerts))
            HStack {
                Text("CPU threshold")
                Slider(value: Binding(get: { monitor.threshold }, set: monitor.setThreshold), in: 40...110, step: 1)
                Text(monitor.preferences.unit.format(monitor.threshold, decimals: false)).monospacedDigit().frame(width: 58)
            }
            Picker("Must stay above for", selection: binding(\.sustainSeconds)) {
                ForEach([0.0, 5, 15, 30, 60], id: \.self) { Text($0 == 0 ? "Immediate" : "\(Int($0)) seconds").tag($0) }
            }
            Picker("Minimum time between alerts", selection: binding(\.cooldownSeconds)) {
                ForEach([60.0, 300, 600, 1800], id: \.self) { Text("\(Int($0 / 60)) minutes").tag($0) }
            }
            Text("Alerts use the hottest mapped CPU reading. A new alert requires cooling by 3 °C below the threshold first. Missing readings and sleep restart the sustained-temperature timer.").font(.callout).foregroundStyle(.secondary)
            Text("Conditions are checked at each sample (currently every \(Int(monitor.effectiveInterval)) seconds). Notifications may arrive later when sampling is slower.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func rowName(_ id: String) -> String {
        switch id { case "F0Ac": return "Fan 1"; case "F1Ac": return "Fan 2"; default: return id }
    }
}
