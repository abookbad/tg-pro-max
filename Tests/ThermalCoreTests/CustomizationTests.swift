import XCTest
import ThermalCore

final class CustomizationTests: XCTestCase {
    func testPreferencesRoundTripAndLayoutRepair() throws {
        var p = Preferences()
        p.menuMetric = .both; p.unit = .fahrenheit; p.appearance = .light
        p.hiddenRows = [Component.gpu.rawValue]
        p.moveRow("F1Ac", by: -1)
        let saved = try JSONEncoder().encode(p)
        XCTAssertEqual(try JSONDecoder().decode(Preferences.self, from: saved), p)
        p.rowOrder = ["GPU", "GPU", "unknown"]
        p.hiddenRows.insert("unknown")
        p.interval = -1; p.warningThreshold = .nan
        p.normalize()
        XCTAssertEqual(p.rowOrder.count, 6)
        XCTAssertEqual(p.rowOrder.first, "GPU")
        XCTAssertEqual(Set(p.rowOrder).count, 6)
        XCTAssertFalse(p.hiddenRows.contains("unknown"))
        XCTAssertEqual(p.interval, 1)
        XCTAssertEqual(p.warningThreshold, 85)
    }
    func testMenuFormattingAndUnitConversionDoNotInventReadings() {
        var p = Preferences()
        p.menuMetric = .both
        XCTAssertEqual(p.menuTitle(values: [.cpu: 50]), "C 50°C  G —")
        p.menuDecimals = true; p.unit = .fahrenheit
        XCTAssertEqual(p.menuTitle(values: [.cpu: 50, .gpu: 40]), "C 122.0°F  G 104.0°F")
        p.menuMetric = .icon
        XCTAssertEqual(p.menuTitle(values: [.cpu: 50]), "")
        XCTAssertEqual(TemperatureUnit.fahrenheit.format(nil), "—")
    }
    func testBatteryIntervalNeverIncreasesPollingRate() {
        var p = Preferences()
        p.slowerOnBattery = true
        XCTAssertEqual(p.effectiveInterval(onBattery: true), 5)
        XCTAssertEqual(p.effectiveInterval(onBattery: false), 1)
        p.interval = 10
        XCTAssertEqual(p.effectiveInterval(onBattery: true), 10)
        p.slowerOnBattery = false; p.interval = 2
        XCTAssertEqual(p.effectiveInterval(onBattery: true), 2)
    }
    func testSustainedAlertRejectsSpikesMissingSamplesAndSleep() {
        var gate = AlertGate()
        let start = Date(timeIntervalSince1970: 10000)
        func tick(_ second: Double, _ value: Double?) -> Bool {
            gate.shouldAlert(value: value, threshold: 90, now: start.addingTimeInterval(second), sustain: 15, cooldown: 60, maximumGap: 11)
        }
        XCTAssertFalse(tick(0, 91))
        XCTAssertFalse(tick(5, 89)) // a brief dip cancels the pending event
        XCTAssertFalse(tick(10, 91))
        XCTAssertFalse(tick(20, nil))
        XCTAssertFalse(tick(25, 91))
        XCTAssertFalse(tick(35, 91))
        XCTAssertFalse(tick(100, 91)) // a long wake gap cannot satisfy the duration
        XCTAssertFalse(tick(110, 91))
        XCTAssertTrue(tick(115, 91))
        XCTAssertFalse(tick(125, 91)) // sustained high state is not repeated
        XCTAssertFalse(tick(130, 86)) // rearm
        XCTAssertFalse(tick(135, 91))
        XCTAssertFalse(tick(145, 91))
        XCTAssertFalse(tick(150, 91)) // cooldown still active
        XCTAssertFalse(tick(160, 91))
        XCTAssertFalse(tick(170, 91))
        XCTAssertTrue(tick(175, 91))
    }
    func testGraphCadenceChangesAndMissingChannelsCreateCorrectSegments() {
        var h = History()
        let start = Date(timeIntervalSince1970: 10000)
        for t in [0.0, 5, 10] { h.append(Sample(date: start.addingTimeInterval(t), values: [.cpu: 70, .gpu: 50], interval: 5)) }
        h.append(Sample(date: start.addingTimeInterval(11), values: [.cpu: 71], interval: 1))
        h.append(Sample(date: start.addingTimeInterval(12), values: [.cpu: 72, .gpu: 52], interval: 1))
        h.append(Sample(date: start.addingTimeInterval(100), values: [.cpu: 73, .gpu: 53], interval: 1))
        let points = h.points(for: [.cpu, .gpu])
        let cpu = points.filter { $0.component == .cpu }
        let gpu = points.filter { $0.component == .gpu }
        XCTAssertEqual(cpu.map(\.segment), [0, 0, 0, 0, 0, 1])
        XCTAssertEqual(gpu.map(\.segment), [0, 0, 0, 1, 2])
        XCTAssertEqual(Set(points.map(\.id)).count, points.count)
        XCTAssertEqual(h.samples.count, 6)
    }
    func testHistoryRemainsBoundedAtEverySupportedCadence() {
        for cadence in [1.0, 2, 5, 10] {
            var h = History()
            for i in 0...1800 {
                h.append(Sample(date: Date(timeIntervalSince1970: Double(i) * cadence), values: [.cpu: 50], interval: cadence))
            }
            XCTAssertEqual(h.samples.count, Int(600 / cadence))
        }
    }
}
