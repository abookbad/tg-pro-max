import XCTest
@testable import ThermalCore

final class ProcessWatchTests: XCTestCase {
    let home = "/Users/me"
    let now = Date(timeIntervalSince1970: 1_000_000)
    func ago(_ s: TimeInterval) -> Int64 { Int64(now.timeIntervalSince1970 - s) }

    /// The real case: `npm run start:test` → node wrapper → next-server, launched from a worktree, launcher exited.
    func imsaTree(cpu: Double = 98, age: TimeInterval = 6 * 86400, orphan: Bool = true) -> [ProcInfo] {
        let dir = "\(home)/Desktop/CursorProjects/imsa-website/.claude/worktrees/help-desk"
        return [
            ProcInfo(pid: 40, ppid: 1, name: "iTerm2", start: ago(age + 90)),
            ProcInfo(pid: 50, ppid: 40, name: "zsh", start: ago(age + 60)),
            ProcInfo(pid: 100, ppid: orphan ? 1 : 50, name: "node", start: ago(age), args: ["npm", "run", "start:test", "--port", "3019"], cwd: dir),
            ProcInfo(pid: 101, ppid: 100, name: "sh", start: ago(age)),
            ProcInfo(pid: 102, ppid: 101, name: "node", start: ago(age), args: ["node", "supabase/tools/next-with-env.mjs", ".env.test", "start", "--port", "3019"], cwd: dir),
            ProcInfo(pid: 103, ppid: 102, name: "node", start: ago(age), cpu: cpu, args: ["next-server (v16.3.5)"], cwd: dir, ports: [3019, 62423]),
            ProcInfo(pid: 200, ppid: 1, name: "Spotify Helper", start: ago(3600), cpu: 5, path: "/Applications/Spotify.app/Contents/Frameworks/Spotify Helper.app/Contents/MacOS/Spotify Helper")
        ]
    }

    func testOrphanedTestServerIsNamedByProjectAndStoppedAsOneTree() {
        var watch = ProcessWatch()
        let items = watch.evaluate(imsaTree(), now: now, settings: WatchSettings(), home: home) { _ in nil }
        XCTAssertEqual(items.count, 1)
        let item = items[0]
        XCTAssertEqual(item.title, "IMSA Website · Next.js server (test)")
        XCTAssertEqual(item.detail, "help-desk worktree · :3019 · up 6d 0h")
        XCTAssertEqual(item.pids, [103, 102, 101, 100], "children first, launcher last, unrelated shell untouched")
        XCTAssertEqual(Set(item.flags), [.leftover, .stale])
        XCTAssertTrue(ProcessWatch.shouldAutoStop(item, settings: WatchSettings()))
        var off = WatchSettings(); off.autoStop = false
        XCTAssertFalse(ProcessWatch.shouldAutoStop(item, settings: off))
    }

    func testAttachedFreshDevServerIsListedButNotFlagged() {
        var watch = ProcessWatch()
        let item = watch.evaluate(imsaTree(cpu: 2, age: 1800, orphan: false), now: now, settings: WatchSettings(), home: home) { _ in nil }[0]
        XCTAssertTrue(item.isDevServer)
        XCTAssertTrue(item.flags.isEmpty)
        XCTAssertFalse(item.detail.contains("launcher gone"))
        XCTAssertFalse(ProcessWatch.shouldAutoStop(item, settings: WatchSettings()))
    }

    func testRunawayNeedsSustainedCPU() {
        var watch = ProcessWatch()
        let procs = imsaTree(cpu: 95, age: 1800, orphan: false)
        XCTAssertTrue(watch.evaluate(procs, now: now, settings: WatchSettings(), home: home) { _ in nil }[0].flags.isEmpty)
        let later = watch.evaluate(procs, now: now.addingTimeInterval(601), settings: WatchSettings(), home: home) { _ in nil }[0]
        XCTAssertEqual(later.flags, [.runaway])
        var calm = procs; calm[5].cpu = 1
        _ = watch.evaluate(calm, now: now.addingTimeInterval(615), settings: WatchSettings(), home: home) { _ in nil }
        XCTAssertTrue(watch.evaluate(procs, now: now.addingTimeInterval(630), settings: WatchSettings(), home: home) { _ in nil }[0].flags.isEmpty, "a calm scan resets the timer")
    }

    func testBusyAppIsReportedNotAutoStopped() {
        var watch = ProcessWatch()
        var procs = imsaTree(cpu: 0, age: 600, orphan: false)
        procs[6].cpu = 90
        var settings = WatchSettings(); settings.runawayMinutes = 2
        _ = watch.evaluate(procs, now: now, settings: settings, home: home) { _ in nil }
        let app = watch.evaluate(procs, now: now.addingTimeInterval(130), settings: settings, home: home) { _ in nil }.first { !$0.isDevServer }!
        XCTAssertEqual(app.title, "Spotify · Spotify Helper")
        XCTAssertEqual(app.flags, [.runaway])
        XCTAssertFalse(ProcessWatch.shouldAutoStop(app, settings: settings))
    }

    func testLabels() {
        XCTAssertEqual(DevKind.label("node /p/node_modules/.bin/next dev --turbopack"), "Next.js dev server")
        XCTAssertEqual(DevKind.label("node /p/node_modules/.bin/vite --port 5173"), "Vite dev server")
        XCTAssertEqual(DevKind.label("python manage.py runserver"), "Django server")
        XCTAssertEqual(DevKind.label("node /p/node_modules/.bin/vitest"), "Test watcher")
        XCTAssertNil(DevKind.label("node /Users/me/.npm/_npx/x/node_modules/.bin/mcp-server-playwright"))
        XCTAssertNil(DevKind.label("node /Users/me/.local/bin/claude --resume"))
        XCTAssertNotNil(DevKind.label("node /Users/me/Desktop/CursorProjects/x/.claude/worktrees/y/node_modules/.bin/next dev"), "folder names are not tool names")
        XCTAssertEqual(DevKind.port(["next", "dev", "--port=3005"]), 3005)
        XCTAssertNil(DevKind.port(["next", "dev", "--port", "0"]))
    }

    func testProjectNames() {
        XCTAssertEqual(ProjectName.pretty("imsa-website"), "IMSA Website")
        XCTAssertEqual(ProjectName.pretty("nhs-erp-frontend"), "NHS ERP Frontend")
        XCTAssertEqual(ProjectName.pretty("tg-pro-max"), "TG Pro Max")
        XCTAssertEqual(ProjectName.pretty("mmerp-v2"), "Mmerp v2")
        let parsed = ProjectName.parse("\(home)/x/relay/.claude/worktrees/orb/Sources", home: home) { _ in nil }
        XCTAssertEqual(parsed?.project, "Relay"); XCTAssertEqual(parsed?.worktree, "orb")
        XCTAssertEqual(ProjectName.parse("\(home)/x/adw-site/apps/web", home: home) { _ in "\(home)/x/adw-site" }?.project, "ADW Site")
        XCTAssertNil(ProjectName.parse("/", home: home) { _ in nil })
    }

    func testRedactionAndSettingsDecoding() throws {
        let r = Redact.text("node server.js --token=abc123 OPENAI_API_KEY=sk-proj-AAAAAAAAAAAAAAAAAAAA x")
        XCTAssertFalse(r.contains("abc123")); XCTAssertFalse(r.contains("sk-proj-AAAA"))
        let decoded = try JSONDecoder().decode(WatchSettings.self, from: Data(#"{"autoStop":false,"maxAgeHours":7}"#.utf8))
        XCTAssertFalse(decoded.autoStop)
        XCTAssertEqual(decoded.maxAgeHours, 24, "invalid values fall back")
        XCTAssertEqual(decoded.runawayCPU, 80, "missing keys keep defaults")
    }
}
