import Foundation

public enum Component: String, CaseIterable, Identifiable, Sendable, Codable {
    case cpu = "CPU / SoC", gpu = "GPU", battery = "Battery", ssd = "SSD / NAND"
    public var id: String { rawValue }
    // Community mappings, not an Apple-documented package temperature or core topology.
    public static let m5CPU = ["Tp00","Tp04","Tp08","Tp0C","Tp0G","Tp0K","Tp0O","Tp0R","Tp0U","Tp0X","Tp0a","Tp0d","Tp0g","Tp0j","Tp0m","Tp0p","Tp0u","Tp0y"]
    public static let m5GPU = ["Tg0U","Tg0X","Tg0d","Tg0g","Tg0j","Tg1Y","Tg1c","Tg1g"]
    public static func group(_ key: String, isM5: Bool) -> Component? {
        if isM5 ? m5CPU.contains(key) : (key.hasPrefix("Tp") || key.hasPrefix("Te")) { return .cpu }
        if isM5 ? m5GPU.contains(key) : key.hasPrefix("Tg") { return .gpu }
        if ["TB1T", "TB2T"].contains(key) { return .battery }
        if key == "TH0x" { return .ssd }
        return nil
    }
}
public struct Sample: Identifiable, Sendable {
    public let date: Date
    public let values: [Component: Double]
    public let interval: TimeInterval
    public var id: Date { date }
    public init(date: Date, values: [Component: Double], interval: TimeInterval = 1) { self.date = date; self.values = values; self.interval = interval }
}
public struct History: Sendable {
    public private(set) var samples: [Sample] = []
    public init() {}
    public mutating func append(_ sample: Sample) {
        samples.append(sample)
        samples.removeAll { $0.date <= sample.date.addingTimeInterval(-600) }
        if samples.count > 600 { samples.removeFirst(samples.count - 600) }
    }
    public func statistics(for component: Component) -> (average: Double, max: Double)? {
        let values = samples.compactMap { $0.values[component] }
        guard !values.isEmpty else { return nil }
        return (values.reduce(0,+) / Double(values.count), values.max()!)
    }
}
public struct AlertGate {
    private var armed = true
    private var lastAlert: Date?
    private var aboveSince: Date?
    private var lastEvaluation: Date?
    public init() {}
    public mutating func reset() { armed = true; interrupt() }
    // Missing samples, sleep and cadence changes cannot count toward a sustained event.
    public mutating func interrupt() { aboveSince = nil; lastEvaluation = nil }
    public mutating func shouldAlert(value: Double?, threshold: Double, now: Date,
                                     sustain: TimeInterval = 0, cooldown: TimeInterval = 300,
                                     maximumGap: TimeInterval = .infinity) -> Bool {
        if let previous = lastEvaluation, now < previous || now.timeIntervalSince(previous) > maximumGap { aboveSince = nil }
        lastEvaluation = now
        guard let value, value.isFinite else { aboveSince = nil; return false }
        if value <= threshold - 3 { armed = true }
        guard value > threshold else { aboveSince = nil; return false }
        if aboveSince == nil { aboveSince = now }
        guard armed, now.timeIntervalSince(aboveSince!) >= sustain,
              lastAlert.map({ now.timeIntervalSince($0) >= cooldown }) ?? true else { return false }
        armed = false; lastAlert = now; return true
    }
}

public struct ChartPoint: Identifiable {
    public let date: Date
    public let value: Double
    public let component: Component
    public let segment: Int
    public var id: String { "\(component.rawValue)-\(date.timeIntervalSince1970)" }
    public var series: String { "\(component.rawValue)-\(segment)" }
}
public extension History {
    func points(for components: [Component]) -> [ChartPoint] {
        components.flatMap { component in
            var segment = 0
            var previous: Sample?
            return samples.compactMap { sample -> ChartPoint? in
                guard let value = sample.values[component] else { segment += 1; previous = nil; return nil }
                if let previous, sample.date.timeIntervalSince(previous.date) > max(sample.interval, previous.interval) * 1.5 + 0.5 { segment += 1 }
                previous = sample
                return ChartPoint(date: sample.date, value: value, component: component, segment: segment)
            }
        }
    }
}
