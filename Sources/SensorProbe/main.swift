import Foundation
import ThermalCore
let reader = SMCReader()
print(reader.status)
for r in reader.read() { print(String(format: "%@ [%@] %.2f %@", r.key, r.type, r.value, r.key.hasPrefix("F") ? "RPM" : "°C")) }
print("Thermal pressure raw state: \(ProcessInfo.processInfo.thermalState.rawValue)")
