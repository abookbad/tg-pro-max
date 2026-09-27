import XCTest
import ThermalCore
import CSMC

final class ThermalCoreTests: XCTestCase {
    func decode(_ type: String, _ bytes: [UInt8]) -> Double? {
        var value = 0.0
        return tg_smc_decode(SMCReader.code(type), bytes, UInt32(bytes.count), &value) ? value : nil
    }
    func testSensorWireFormatsAndInvalidPayloads() {
        XCTAssertEqual(decode("flt ", [0, 0, 72, 66]), 50)
        XCTAssertEqual(decode("sp78", [0x32, 0x80]), 50.5)
        XCTAssertEqual(decode("sp78", [0xff, 0x80]), -0.5)
        XCTAssertEqual(decode("fpe2", [0x1f, 0x40]), 2000)
        XCTAssertEqual(decode("flt ", [0, 0, 0, 0]), 0) // valid fan stop
        XCTAssertEqual(decode("ui32", [0, 0, 1, 0]), 256)
        XCTAssertNil(decode("flt ", [0, 0, 0x80, 0x7f])) // infinity
        XCTAssertNil(decode("flt ", [0, 0, 0xc0, 0x7f])) // NaN
        XCTAssertNil(decode("flt ", [0, 0]))
        XCTAssertNil(decode("????", [0, 0, 0, 0]))
    }
    func testHistoryWindowMissingReadingsAndWakeGap() {
        var h = History()
        let start = Date(timeIntervalSince1970: 10000)
        for i in 0...600 { h.append(Sample(date: start.addingTimeInterval(Double(i)), values: [.cpu: Double(i)])) }
        XCTAssertEqual(h.samples.count, 600)
        XCTAssertEqual(h.statistics(for: .cpu)?.average, 300.5)
        XCTAssertEqual(h.statistics(for: .cpu)?.max, 600)
        XCTAssertNil(h.statistics(for: .gpu))
        h.append(Sample(date: start.addingTimeInterval(1201), values: [:]))
        XCTAssertEqual(h.samples.count, 1)
        XCTAssertNil(h.statistics(for: .cpu))
    }
    func testAlertHysteresisCooldownAndMissingSensors() {
        var gate = AlertGate()
        let now = Date(timeIntervalSince1970: 10000)
        XCTAssertFalse(gate.shouldAlert(value: nil, threshold: 90, now: now))
        XCTAssertFalse(gate.shouldAlert(value: 90, threshold: 90, now: now))
        XCTAssertTrue(gate.shouldAlert(value: 91, threshold: 90, now: now))
        XCTAssertFalse(gate.shouldAlert(value: 95, threshold: 90, now: now.addingTimeInterval(400)))
        XCTAssertFalse(gate.shouldAlert(value: 87, threshold: 90, now: now.addingTimeInterval(401)))
        XCTAssertTrue(gate.shouldAlert(value: 91, threshold: 90, now: now.addingTimeInterval(402)))
        XCTAssertFalse(gate.shouldAlert(value: 80, threshold: 90, now: now.addingTimeInterval(403)))
        XCTAssertFalse(gate.shouldAlert(value: 95, threshold: 90, now: now.addingTimeInterval(404)))
        XCTAssertTrue(gate.shouldAlert(value: 95, threshold: 90, now: now.addingTimeInterval(703)))
    }
    func testMappingsDoNotInventUnknownComponents() {
        XCTAssertEqual(Component.group("Tp00", isM5: true), .cpu)
        XCTAssertEqual(Component.group("Tg0U", isM5: true), .gpu)
        XCTAssertEqual(Component.group("TH0x", isM5: true), .ssd)
        XCTAssertNil(Component.group("Tf06", isM5: true))
        XCTAssertNil(Component.group("Tp1E", isM5: true))
    }
}
