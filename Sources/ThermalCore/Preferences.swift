import Foundation

public enum MenuMetric: String, Codable, CaseIterable, Identifiable {
    case cpu = "CPU", gpu = "GPU", both = "CPU + GPU", battery = "Battery", ssd = "SSD", icon = "Icon only"
    public var id: String { rawValue }
    public var components: [Component] {
        switch self { case .cpu: return [.cpu]; case .gpu: return [.gpu]; case .both: return [.cpu, .gpu]; case .battery: return [.battery]; case .ssd: return [.ssd]; case .icon: return [] }
    }
}
public enum Appearance: String, Codable, CaseIterable, Identifiable {
    case system = "System", dark = "Dark", light = "Light"
    public var id: String { rawValue }
}
public enum Tint: String, Codable, CaseIterable, Identifiable {
    case mint = "Mint", blue = "Blue", purple = "Purple", orange = "Orange"
    public var id: String { rawValue }
}
public enum TemperatureUnit: String, Codable, CaseIterable, Identifiable {
    case celsius = "°C", fahrenheit = "°F"
    public var id: String { rawValue }
    public func convert(_ value: Double) -> Double { self == .fahrenheit ? value * 9 / 5 + 32 : value }
    public func format(_ value: Double?, decimals: Bool = true, suffix: Bool = true) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: decimals ? "%.1f" : "%.0f", convert(value)) + (suffix ? " \(rawValue)" : "")
    }
}
public struct Preferences: Codable, Equatable {
    public var menuMetric: MenuMetric = .cpu
    public var menuIcon = true
    public var menuDecimals = false
    public var menuColor = false
    public var warningThreshold = 85.0 // Celsius, independent of notification thresholds.
    public var unit: TemperatureUnit = .celsius
    public var appearance: Appearance = .dark
    public var tint: Tint = .mint
    public var compact = false
    public var rowOrder = Component.allCases.map(\.rawValue) + ["F0Ac", "F1Ac"]
    public var hiddenRows: Set<String> = []
    public var interval = 1.0
    public var slowerOnBattery = false
    public var batteryInterval = 5.0
    public var showGraph = true
    public var overlay = false
    public var sustainSeconds = 15.0
    public var cooldownSeconds = 300.0
    public init() {}
    public func effectiveInterval(onBattery: Bool) -> Double {
        onBattery && slowerOnBattery ? max(interval, batteryInterval) : interval
    }
    public mutating func normalize() {
        if ![1.0, 2, 5, 10].contains(interval) { interval = 1 }
        if ![1.0, 2, 5, 10].contains(batteryInterval) { batteryInterval = 5 }
        if ![0.0, 5, 15, 30, 60].contains(sustainSeconds) { sustainSeconds = 15 }
        if ![60.0, 300, 600, 1800].contains(cooldownSeconds) { cooldownSeconds = 300 }
        warningThreshold = warningThreshold.isFinite ? min(110, max(40, warningThreshold)) : 85
        let allowed = Self().rowOrder
        var seen: Set<String> = []
        rowOrder = (rowOrder + allowed).filter { allowed.contains($0) && seen.insert($0).inserted }
        hiddenRows.formIntersection(allowed)
    }
    public mutating func moveRow(_ id: String, by offset: Int) {
        guard let index = rowOrder.firstIndex(of: id), rowOrder.indices.contains(index + offset) else { return }
        rowOrder.swapAt(index, index + offset)
    }
    public func menuTitle(values: [Component: Double]) -> String {
        menuMetric.components.map { component in
            let prefix = menuMetric == .both ? (component == .cpu ? "C " : "G ") : ""
            let number = unit.format(values[component], decimals: menuDecimals, suffix: false)
            return prefix + number + (values[component] == nil ? "" : unit.rawValue)
        }.joined(separator: "  ")
    }
}
