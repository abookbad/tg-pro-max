import Foundation
import Darwin
import CProc

/// Reads the process table through libproc (no shell commands). Not thread-safe: use from one serial queue.
public final class ProcessTable {
    private var previous: [Int32: (start: Int64, ns: UInt64)] = [:]
    private var previousAt: UInt64 = 0
    private var cache: [Int32: (start: Int64, path: String, args: [String])] = [:]
    private let uid = getuid()
    private let me = getpid()
    public init() {}

    /// This user's processes with CPU % since the previous call. Command lines, folders and ports are read only for
    /// runtimes (node, python…), their shells, and anything above 10 % CPU.
    public func scan() -> [ProcInfo] {
        var raw = [tg_proc](repeating: tg_proc(), count: 8192)
        let count = Int(tg_list(&raw, Int32(raw.count)))
        let now = DispatchTime.now().uptimeNanoseconds
        let wall = previousAt == 0 ? 0 : Double(now - previousAt)
        var current: [Int32: (start: Int64, ns: UInt64)] = [:]
        var out: [ProcInfo] = []
        for r in raw.prefix(count) where r.uid == uid && r.pid != me {
            let name = withUnsafeBytes(of: r.name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let ns = tg_cpu_ns(r.pid)
            current[r.pid] = (r.start, ns)
            var cpu = 0.0
            if wall > 0, let p = previous[r.pid], p.start == r.start, ns >= p.ns { cpu = Double(ns - p.ns) / wall * 100 }
            var info = ProcInfo(pid: r.pid, ppid: r.ppid, name: name, start: r.start, cpu: cpu)
            let runtime = ProcessWatch.runtimes.contains(name) || name.hasPrefix("python") || name.hasPrefix("next-")
            if runtime || ProcessWatch.shells.contains(name) || cpu >= 10 {
                if let c = cache[r.pid], c.start == r.start { info.path = c.path; info.args = c.args }
                else {
                    info.path = Self.string(256 * 4) { tg_path(r.pid, $0, $1) } ?? ""
                    info.args = (Self.string(16_384) { tg_args(r.pid, $0, $1) } ?? "").split(separator: "\n").map(String.init)
                    cache[r.pid] = (r.start, info.path, info.args)
                }
                info.cwd = Self.string(1024) { tg_cwd(r.pid, $0, $1) }
                if runtime, DevKind.framework(info.text) != nil {
                    var ports = [UInt16](repeating: 0, count: 16)
                    info.ports = Array(ports.prefix(Int(tg_listen_ports(r.pid, &ports, 16))))
                }
            }
            out.append(info)
        }
        previous = current; previousAt = now
        cache = cache.filter { current[$0.key]?.start == $0.value.start }
        return out
    }

    /// Signals only if the pid still belongs to the same process start (avoids hitting a reused pid).
    @discardableResult
    public static func signal(_ pid: Int32, start: Int64, _ sig: Int32) -> Bool {
        guard pid > 1, pid != getpid(), tg_start(pid) == start else { return false }
        return kill(pid, sig) == 0
    }
    public static func isAlive(_ pid: Int32, start: Int64) -> Bool { tg_start(pid) == start }

    private static func string(_ size: Int, _ read: (UnsafeMutablePointer<CChar>, Int32) -> Int32) -> String? {
        var buf = [CChar](repeating: 0, count: size)
        guard read(&buf, Int32(size)) == 0 else { return nil }
        let s = String(cString: buf)
        return s.isEmpty ? nil : s
    }
}

/// Nearest folder at or above `path` that looks like a project (.git or package.json), stopping at home.
public enum ProjectRoot {
    nonisolated(unsafe) private static var memo: [String: String?] = [:]
    public static func find(_ path: String) -> String? {
        if let hit = memo[path] { return hit }
        let fm = FileManager.default, home = NSHomeDirectory()
        var dir = path, found: String?
        while dir.count > home.count {
            if fm.fileExists(atPath: dir + "/.git") || fm.fileExists(atPath: dir + "/package.json") { found = dir }
            if fm.fileExists(atPath: dir + "/.git") { break }      // the repo root wins over nested packages
            dir = (dir as NSString).deletingLastPathComponent
        }
        if memo.count > 500 { memo.removeAll() }
        memo[path] = found
        return found
    }
}
