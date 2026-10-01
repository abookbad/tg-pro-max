import SwiftUI
import Charts
import ThermalCore

struct Dashboard: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject var processes: ProcessWatcher
    @Environment(\.colorScheme) private var systemScheme
    @State private var details = false
    init(monitor: Monitor) { self.monitor = monitor; self.processes = monitor.processes }
    private var accent: Color {
        monitor.preferences.tint == .mint && scheme == .light ? Color(red: 0.06, green: 0.47, blue: 0.34) : monitor.preferences.tint.color
    }
    private var gpuColor: Color { monitor.preferences.tint == .purple ? .orange : .purple }
    private var scheme: ColorScheme { monitor.preferences.appearance.scheme ?? systemScheme }
    private var background: Color { scheme == .dark ? Color(red: 0.075, green: 0.085, blue: 0.095) : Color(nsColor: .windowBackgroundColor) }
    private var panelHeight: CGFloat {
        let rows = visibleRows.count
        return CGFloat((monitor.preferences.compact ? 470 : 500) + rows * (monitor.preferences.compact ? 28 : 36) - (monitor.preferences.showGraph ? (monitor.preferences.overlay ? -24 : 0) : 135) + (details ? 190 : 0) + (monitor.message != nil ? 80 : 0)) + ProcessSection.height(processes, compact: monitor.preferences.compact)
    }
    var body: some View {
        ScrollView { panel }
            .scrollIndicators(.hidden)
            .frame(width: 400, height: min(panelHeight, (NSScreen.main?.visibleFrame.height ?? 900) - 80))
            .background(background)
            .environment(\.colorScheme, scheme)
            .preferredColorScheme(monitor.preferences.appearance.scheme)
    }
    var previewContent: some View { panel.environment(\.colorScheme, scheme) }
    private var panel: some View {
        VStack(alignment: .leading, spacing: monitor.preferences.compact ? 12 : 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Text("TG PRO").font(.system(size: 18, weight: .heavy, design: .rounded))
                        Text("MAX").font(.system(size: 10, weight: .black)).padding(.horizontal, 6).padding(.vertical, 3)
                            .background(accent, in: RoundedRectangle(cornerRadius: 4)).foregroundStyle(.black)
                    }
                    Text(monitor.chip).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Circle().fill(monitor.snapshot?.values.isEmpty == false ? accent : .gray).frame(width: 6, height: 6).padding(.top, 6)
                Text("LIVE · \(Int(monitor.effectiveInterval)) SEC").font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary).padding(.top, 3)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(temperature(monitor.snapshot?.values[monitor.selected], unit: false))
                    .font(.system(size: 56, weight: .light, design: .rounded)).monospacedDigit()
                Text(monitor.preferences.unit.rawValue).font(.title2).foregroundStyle(.secondary)
                Spacer()
                VStack(alignment: .trailing, spacing: 5) {
                    Text(monitor.selected.rawValue).font(.headline)
                    Text("Hottest mapped sensor").font(.caption2).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "waveform.path.ecg").foregroundStyle(pressureColor)
                Text("Thermal pressure").foregroundStyle(.secondary)
                Spacer()
                Text(monitor.pressure).foregroundStyle(pressureColor).fontWeight(.semibold)
            }.font(.caption).padding(10).background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 12) {
                if monitor.preferences.showGraph {
                HStack {
                    Text(monitor.preferences.overlay ? "CPU + GPU HISTORY" : "TEMPERATURE HISTORY").font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary)
                    Spacer()
                    Text("10 MIN").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                }
                historyChart.frame(height: 105)
                HStack { Text("−10 min"); Spacer(); Text("−5 min"); Spacer(); Text("Now") }
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                if monitor.preferences.overlay {
                    HStack(spacing: 12) {
                        Label("CPU", systemImage: "circle.fill").foregroundStyle(accent)
                        Label("GPU", systemImage: "circle.fill").foregroundStyle(gpuColor)
                        Spacer()
                        Text("Stats: \(monitor.selected.rawValue)").foregroundStyle(.secondary)
                    }.font(.system(size: 9))
                }
                }
                HStack {
                    stat("CURRENT", temperature(monitor.snapshot?.values[monitor.selected]))
                    Spacer()
                    stat("AVERAGE", temperature(monitor.history.statistics(for: monitor.selected)?.average))
                    Spacer()
                    stat("PEAK", temperature(monitor.history.statistics(for: monitor.selected)?.max))
                }
            }
            VStack(spacing: 2) {
                ForEach(visibleRows, id: \.self) { id in
                    if let component = Component(rawValue: id) {
                        Button { monitor.selected = component } label: {
                            HStack {
                                Image(systemName: symbol(component)).frame(width: 20).foregroundStyle(monitor.selected == component ? accent : .secondary)
                                Text(component.rawValue)
                                Spacer()
                                Text(temperature(monitor.snapshot?.values[component])).monospacedDigit().fontWeight(.medium)
                                Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(monitor.selected == component ? accent : .clear)
                            }.font(.system(size: 12)).padding(.horizontal, 10).padding(.vertical, monitor.preferences.compact ? 5 : 9)
                                .background(monitor.selected == component ? accent.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 7))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    } else if let fan = monitor.snapshot?.readings.first(where: { $0.key == id }) {
                        HStack {
                            Image(systemName: "fan").frame(width: 20).foregroundStyle(.secondary)
                            Text(id == "F0Ac" ? "Fan 1" : "Fan 2")
                            Spacer()
                            Text("\(Int(fan.value)) RPM").monospacedDigit()
                        }.font(.system(size: 12)).padding(.horizontal, 10).padding(.vertical, monitor.preferences.compact ? 5 : 8)
                    }
                }
            }
            if monitor.snapshot?.values.isEmpty != false {
                Text("Waiting for readable sensors. Unavailable readings are hidden; access is retried automatically.").font(.caption).foregroundStyle(.secondary)
            }
            if details {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Live SMC readings · inferred component labels").font(.caption).fontWeight(.medium)
                    Text("CPU, GPU and battery use the hottest mapped channel. SSD is the NAND sensor, not a SMART composite. No estimated temperatures.").font(.caption2).foregroundStyle(.secondary)
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(monitor.snapshot?.readings ?? []) { reading in
                                HStack {
                                    Text(reading.key).font(.system(.caption, design: .monospaced))
                                    Text(Component.group(reading.key, isM5: monitor.sampler.isM5)?.rawValue ?? "Fan").foregroundStyle(.secondary)
                                    Spacer()
                                    Text(reading.key.hasPrefix("F") ? String(format: "%.0f RPM", reading.value) : temperature(reading.value)).monospacedDigit()
                                }.font(.caption)
                            }
                        }
                    }.frame(height: 120)
                }
            }
            ProcessSection(watch: processes, accent: accent, compact: monitor.preferences.compact)
            if let message = monitor.message {
                HStack(alignment: .top) {
                    Text(message).font(.caption).foregroundStyle(.orange)
                    Button { monitor.message = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }
            }
            Divider()
            HStack {
                Button { details.toggle() } label: { Label("Sensors", systemImage: "list.bullet.rectangle") }
                Spacer()
                Button { monitor.showSettings?() } label: { Image(systemName: "gearshape") }.help("Settings")
                Button { NSApplication.shared.terminate(nil) } label: { Image(systemName: "power") }.help("Quit TG PRO MAX")
            }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
        }
        .padding(22).frame(width: 400)
        .background(background)
        .preferredColorScheme(monitor.preferences.appearance.scheme)
    }
    private var pressureColor: Color { (monitor.snapshot?.pressure ?? -1) < 0 ? .gray : (monitor.snapshot?.pressure ?? 0) < 2 ? accent : .orange }
    private var historyChart: some View {
        let end = monitor.snapshot?.date ?? Date()
        let unit = monitor.preferences.unit
        let points = monitor.history.points(for: monitor.preferences.overlay ? [.cpu, .gpu] : [monitor.selected])
        return Chart(points) { point in
            LineMark(x: .value("Time", point.date), y: .value(unit.rawValue, unit.convert(point.value)), series: .value("Segment", point.series))
                .foregroundStyle(monitor.preferences.overlay && point.component == .gpu ? gpuColor : accent)
                .lineStyle(StrokeStyle(lineWidth: 1.6, dash: monitor.preferences.overlay && point.component == .gpu ? [4, 3] : []))
        }
        .chartXScale(domain: end.addingTimeInterval(-600)...end)
        .chartYScale(domain: unit.convert(0)...unit.convert(max(100, (points.map(\.value).max() ?? 100) + 10)))
        .chartXAxis(.hidden)
        .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in AxisGridLine().foregroundStyle(.primary.opacity(0.06)); AxisValueLabel().font(.system(size: 9)) } }
        .overlay { if points.isEmpty { Text("History appears as readings arrive").font(.caption).foregroundStyle(.secondary) } }
    }
    private var visibleRows: [String] {
        monitor.preferences.rowOrder.filter { id in
            guard !monitor.preferences.hiddenRows.contains(id) else { return false }
            if let component = Component(rawValue: id) { return monitor.snapshot?.values[component] != nil }
            return monitor.snapshot?.readings.contains { $0.key == id } == true
        }
    }
    private func temperature(_ value: Double?, unit: Bool = true) -> String {
        monitor.preferences.unit.format(value, suffix: unit)
    }
    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 8, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 13, weight: .medium, design: .rounded)).monospacedDigit()
        }
    }
    private func symbol(_ c: Component) -> String {
        switch c { case .cpu: return "cpu"; case .gpu: return "square.3.layers.3d"; case .battery: return "battery.100percent"; case .ssd: return "internaldrive" }
    }
}
