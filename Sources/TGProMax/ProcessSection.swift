import SwiftUI
import ThermalCore

/// Popup section: dev servers that are running, anything busy, and what was stopped recently.
struct ProcessSection: View {
    @ObservedObject var watch: ProcessWatcher
    let accent: Color
    let compact: Bool
    static let maxRows = 6

    /// Height the popup needs for this section (the popup sizes itself by hand).
    static func height(_ watch: ProcessWatcher, compact: Bool) -> CGFloat {
        guard watch.settings.enabled else { return 0 }
        let rows = min(watch.items.count, maxRows)
        let explained = watch.items.prefix(maxRows).filter { watch.explanations[$0.id] != nil }.count
        let flagged = watch.items.prefix(maxRows).filter { !$0.flags.isEmpty }.count
        return 34 + CGFloat(max(rows, 1)) * (compact ? 40 : 46) + CGFloat(flagged) * 14 + CGFloat(explained) * 44 + (watch.stopped.isEmpty ? 0 : 22 + CGFloat(min(watch.stopped.count, 2)) * 18)
    }

    var body: some View {
        if watch.settings.enabled {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("PROCESS WATCH").font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary)
                    Spacer()
                    Text(watch.settings.autoStop ? "AUTO-STOP ON" : "REPORT ONLY").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                }
                if watch.items.isEmpty {
                    Text("No dev servers running and nothing busy.").font(.caption).foregroundStyle(.secondary).padding(.vertical, 6)
                }
                ForEach(watch.items.prefix(Self.maxRows)) { item in row(item) }
                if !watch.stopped.isEmpty {
                    Text("RECENTLY STOPPED").font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary).padding(.top, 4)
                    ForEach(watch.stopped.prefix(2)) { entry in
                        Text("\(entry.date.formatted(date: .omitted, time: .shortened)) · \(entry.title)")
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
        }
    }

    private func row(_ item: WatchItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: item.isDevServer ? "server.rack" : "cpu").frame(width: 20)
                    .foregroundStyle(item.flags.isEmpty ? Color.secondary : Color.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.tail).help(item.title)
                    Text(item.detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    if !item.flags.isEmpty {
                        Text(item.flags.map(\.rawValue).joined(separator: " · "))
                            .font(.system(size: 10, weight: .medium)).foregroundStyle(.orange).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Text("\(Int(item.cpu.rounded()))%").font(.system(size: 12, weight: .medium)).monospacedDigit()
                    .foregroundStyle(item.cpu >= watch.settings.runawayCPU ? .orange : .primary).frame(width: 40, alignment: .trailing)
                Button { watch.explain(item) } label: {
                    if watch.explaining.contains(item.id) { ProgressView().controlSize(.mini) } else { Image(systemName: "sparkles") }
                }.buttonStyle(.plain).foregroundStyle(accent).frame(width: 16).help("Explain with AI")
                Button { watch.kill(item) } label: {
                    if watch.stopping.contains(item.id) { ProgressView().controlSize(.mini) } else { Image(systemName: "stop.circle") }
                }.buttonStyle(.plain).foregroundStyle(.secondary).frame(width: 16)
                    .help(item.isDevServer ? "Stop this dev server and its launcher" : "Quit this process")
                    .disabled(watch.stopping.contains(item.id))
            }
            if let why = watch.explanations[item.id] {
                Text(why).font(.caption2).foregroundStyle(.secondary).lineLimit(3).padding(.leading, 28)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, compact ? 4 : 7)
        .background(item.flags.isEmpty ? Color.primary.opacity(0.03) : Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
    }
}

/// Settings → Processes.
struct ProcessSettings: View {
    @ObservedObject var watch: ProcessWatcher
    @State private var key = ""
    @State private var keySource = AIExplainer.keySource
    private func binding<Value>(_ path: WritableKeyPath<WatchSettings, Value>) -> Binding<Value> {
        Binding(get: { watch.settings[keyPath: path] }, set: { watch.settings[keyPath: path] = $0 })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Watch processes", isOn: binding(\.enabled))
            Text("Every 15 seconds (30 on battery) TG PRO MAX reads the process table directly, names dev servers by project and port, and tracks CPU.").font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("DEV SERVERS").font(.caption.bold()).foregroundStyle(.secondary)
            Toggle("Stop flagged dev servers automatically", isOn: binding(\.autoStop))
            Picker("Launcher gone for", selection: binding(\.leftoverMinutes)) { ForEach([5.0, 15, 30, 60], id: \.self) { Text("\(Int($0)) minutes").tag($0) } }
            Picker("Stop any dev server after", selection: binding(\.maxAgeHours)) {
                ForEach([0.0, 6, 12, 24, 48], id: \.self) { Text($0 == 0 ? "Never" : "\(Int($0)) hours").tag($0) }
            }
            Text("A dev server is flagged when the terminal or agent that started it is gone, when it has run longer than the limit, or when it burns CPU. The whole tree (npm, node, next-server…) is stopped together.").font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("RUNAWAY CPU").font(.caption.bold()).foregroundStyle(.secondary)
            HStack {
                Text("Threshold")
                Slider(value: binding(\.runawayCPU), in: 30...200, step: 10)
                Text("\(Int(watch.settings.runawayCPU))%").monospacedDigit().frame(width: 48)
            }
            Picker("Sustained for", selection: binding(\.runawayMinutes)) { ForEach([2.0, 5, 10, 30], id: \.self) { Text("\(Int($0)) minutes").tag($0) } }
            Toggle("Notify me", isOn: binding(\.notify))
            Text("Other apps are never stopped automatically: you get a notification and a Stop button.").font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("AI").font(.caption.bold()).foregroundStyle(.secondary)
            Toggle("Explain runaway alerts with OpenAI", isOn: binding(\.ai))
            HStack {
                Text("Model")
                TextField("gpt-5-mini", text: binding(\.model)).textFieldStyle(.roundedBorder).frame(width: 160)
            }
            HStack {
                SecureField("OpenAI API key (optional)", text: $key).textFieldStyle(.roundedBorder)
                Button("Save") { AIExplainer.saveKey(key); key = ""; keySource = AIExplainer.keySource }
            }
            Label(keySource, systemImage: AIExplainer.hasKey ? "checkmark.circle" : "exclamationmark.circle").font(.caption).foregroundStyle(.secondary)
            Text("AI is called only when you press ✦ or a runaway alert fires. Keys and tokens in command lines are redacted before sending.").font(.caption).foregroundStyle(.secondary)
            if !watch.stopped.isEmpty {
                Divider()
                HStack { Text("STOPPED").font(.caption.bold()).foregroundStyle(.secondary); Spacer(); Button("Clear") { watch.clearLog() } }
                ForEach(watch.stopped) { e in
                    Text("\(e.date.formatted(date: .abbreviated, time: .shortened)) · \(e.title) — \(e.reason)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
