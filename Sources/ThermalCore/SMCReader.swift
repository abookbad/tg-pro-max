import Foundation
import CSMC

public struct SensorReading: Identifiable, Sendable {
    public var id: String { key }
    public let key: String
    public let type: String
    public let value: Double
}

// Confined to the sampler's serial queue (or the probe's main thread).
public final class SMCReader {
    private var connection: UInt32 = 0
    private var keys: [(String, UInt32, TGKeyInfo)] = []
    public private(set) var status = "Not connected"
    public init() { reconnect() }
    deinit { tg_smc_close(connection) }
    public static func code(_ s: String) -> UInt32 { s.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }
    public static func name(_ n: UInt32) -> String {
        String(bytes: [24,16,8,0].map { UInt8((n >> $0) & 255) }, encoding: .ascii) ?? "????"
    }
    public func reconnect() {
        tg_smc_close(connection); keys = []; connection = tg_smc_open()
        guard connection != 0 else { status = "AppleSMC is unavailable"; return }
        var info = TGKeyInfo(); var count = 0.0
        guard tg_smc_info(connection, Self.code("#KEY"), &info),
              tg_smc_read(connection, Self.code("#KEY"), info, &count), count > 0, count < 20000 else {
            status = "Cannot enumerate AppleSMC sensors"; return
        }
        for index in 0..<UInt32(count) {
            var code: UInt32 = 0
            guard tg_smc_key_at(connection, index, &code) else { continue }
            let name = Self.name(code)
            guard name.hasPrefix("T") || (name.hasPrefix("F") && name.hasSuffix("Ac")) else { continue }
            var metadata = TGKeyInfo()
            guard tg_smc_info(connection, code, &metadata) else { continue }
            let type = Self.name(metadata.type)
            guard ["flt ", "sp78", "fpe2"].contains(type) else { continue }
            keys.append((name, code, metadata))
        }
        status = "AppleSMC · \(keys.count) candidate sensors"
    }
    public func read(only selected: Set<String>? = nil) -> [SensorReading] {
        keys.compactMap { name, code, info in
            if let selected, !selected.contains(name) { return nil }
            var value = 0.0
            guard tg_smc_read(connection, code, info, &value) else { return nil }
            // Zero temperature commonly means an inactive/unpopulated channel. Zero RPM is valid.
            guard name.hasPrefix("F") ? (0...20000).contains(value) : (value > 0 && value < 150) else { return nil }
            return SensorReading(key: name, type: Self.name(info.type), value: value)
        }
    }
}
