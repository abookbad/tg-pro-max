import Foundation
import ThermalCore

if CommandLine.arguments.contains("processes") {
    // `swift run SensorProbe processes`: what Process Watch sees right now (read-only, never signals anything).
    let table = ProcessTable()
    _ = table.scan(); Thread.sleep(forTimeInterval: 3)
    var watch = ProcessWatch()
    let home = NSHomeDirectory()
    let items = watch.evaluate(table.scan(), now: Date(), settings: WatchSettings(), home: home, root: ProjectRoot.find)
    for item in items {
        print(String(format: "%5.1f%%  %@", item.cpu, item.title))
        print("        \(item.detail)\(item.flags.isEmpty ? "" : "  [" + item.flags.map(\.rawValue).joined(separator: ", ") + "]")\(ProcessWatch.shouldAutoStop(item, settings: WatchSettings()) ? "  → would auto-stop" : "")  pids \(item.pids)")
    }
    exit(0)
}
let reader = SMCReader()
print(reader.status)
for r in reader.read() { print(String(format: "%@ [%@] %.2f %@", r.key, r.type, r.value, r.key.hasPrefix("F") ? "RPM" : "°C")) }
print("Thermal pressure raw state: \(ProcessInfo.processInfo.thermalState.rawValue)")
