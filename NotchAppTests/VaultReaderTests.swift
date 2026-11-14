import XCTest

final class VaultReaderTests: XCTestCase {
    var vault: URL!
    let now = ISO8601DateFormatter().date(from: "2026-11-14T12:00:00Z")!

    override func setUpWithError() throws {
        vault = FileManager.default.temporaryDirectory.appendingPathComponent("vault-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: vault) }

    @discardableResult
    func note(_ agent: String, _ id: String, title: String, project: String, updated: String, file: String? = nil,
              started: String? = nil, turns: Int = 3) throws -> URL {
        let dir = vault.appendingPathComponent("Sessions/\(agent)/2026-11")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(file ?? "2026-11-14-\(project)-\(id).md")
        let fm = "---\nagent: \"\(agent)\"\nproject: \"\(project)\"\ntitle: \"\(title)\"\nstarted: \"\(started ?? updated)\"\nupdated: \"\(updated)\"\nturns: \(turns)\n---\n\n# \(title)\n"
        try fm.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
    func status(lastRun: String, agents: String = "{}") throws {
        let dir = vault.appendingPathComponent(".recorder")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "{\"last_run\": \"\(lastRun)\", \"agents\": \(agents), \"errors\": []}".write(to: dir.appendingPathComponent("status.json"), atomically: true, encoding: .utf8)
    }

    func testSnapshotCountsAndLastPerAgent() throws {
        try note("claude-code", "a1", title: "Older cc", project: "notch", updated: "2026-11-13T09:00:00.500Z")
        let newest = try note("claude-code", "a2", title: "Newest cc", project: "notch", updated: "2026-11-14T10:00:00Z")
        try note("codex", "b1", title: "Codex one", project: "auth", updated: "2026-11-12T10:00:00Z")
        try status(lastRun: "2026-11-14T11:59:30Z")
        let s = VaultReader.snapshot(vault: vault, now: now)
        XCTAssertEqual(s.totalSessions, 3)
        XCTAssertEqual(s.todayCount, 1)
        XCTAssertEqual(s.agents.map(\.name), ["claude-code", "codex"])
        let cc = s.agents[0]
        XCTAssertEqual(cc.sessions, 2); XCTAssertEqual(cc.lastTitle, "Newest cc")
        XCTAssertEqual(cc.lastProject, "notch")
        XCTAssertEqual(cc.notePath.resolvingSymlinksInPath(), newest.resolvingSymlinksInPath())
    }

    func testStaleHeartbeatMarksRecorderDown() throws {
        try note("codex", "b1", title: "x", project: "p", updated: "2026-11-14T10:00:00Z")
        try status(lastRun: "2026-11-14T11:59:00Z")
        XCTAssertTrue(VaultReader.snapshot(vault: vault, now: now).recorderOK)
        try status(lastRun: "2026-11-14T11:50:00Z")
        XCTAssertFalse(VaultReader.snapshot(vault: vault, now: now).recorderOK)
    }

    func testIgnoresConflictFiles() throws {
        try note("codex", "b1", title: "Real", project: "p", updated: "2026-11-14T10:00:00Z")
        try note("codex", "b1", title: "CONFLICT", project: "p", updated: "2027-01-01T00:00:00Z", file: "2026-11-14-p-b1.sync-conflict-20261114-X.md")
        let s = VaultReader.snapshot(vault: vault, now: now)
        XCTAssertEqual(s.totalSessions, 1); XCTAssertEqual(s.agents[0].lastTitle, "Real")
        XCTAssertTrue(VaultReader.search(vault: vault, query: "CONFLICT").isEmpty)
    }

    func testEmptyVaultGivesZeroSnapshot() {
        let s = VaultReader.snapshot(vault: vault, now: now)
        XCTAssertEqual(s, VaultSnapshot(totalSessions: 0, todayCount: 0, recorderOK: false, agents: []))
        XCTAssertEqual(VaultReader.snapshot(vault: vault.appendingPathComponent("missing"), now: now).totalSessions, 0)
    }

    func testSearchMatchesTitleAndProject() throws {
        try note("claude-code", "a1", title: "Keychain prompt fix", project: "auth-lock", updated: "2026-11-14T10:00:00Z")
        try note("codex", "b1", title: "Sky colour", project: "science", updated: "2026-11-14T11:00:00Z")
        XCTAssertEqual(VaultReader.search(vault: vault, query: "keychain").map(\.lastTitle), ["Keychain prompt fix"])
        XCTAssertEqual(VaultReader.search(vault: vault, query: "SCIENCE").map(\.lastTitle), ["Sky colour"])
        XCTAssertEqual(VaultReader.search(vault: vault, query: "").count, 2) // empty query lists everything, newest first
    }

    func testSelectionNeverLandsOnARowThatIsNotDrawn() {
        // 30 search hits, only 6 drawn
        XCTAssertEqual(VaultReader.moveIndex(5, by: 1, rows: 30, visible: 6), 0)
        XCTAssertEqual(VaultReader.moveIndex(0, by: -1, rows: 30, visible: 6), 5)
        XCTAssertEqual(VaultReader.moveIndex(2, by: 1, rows: 3, visible: 6), 0)
        XCTAssertEqual(VaultReader.moveIndex(0, by: 1, rows: 0, visible: 6), 0)
    }

    // MARK: activity + projects pages

    var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }

    func testActivityCountsStartAndUpdateDays() throws {
        try note("claude-code", "a1", title: "Long one", project: "notch", updated: "2026-11-14T10:00:00Z", started: "2026-11-12T09:00:00Z")
        try note("codex", "b1", title: "Same day", project: "auth", updated: "2026-11-14T11:00:00Z")
        let g = VaultReader.activity(vault: vault, days: 5, now: now, calendar: utc)
        XCTAssertEqual(g.days.count, 5)
        XCTAssertEqual(utc.component(.day, from: g.days.first!), 10); XCTAssertEqual(utc.component(.day, from: g.days.last!), 14)
        XCTAssertEqual(g.agents, ["claude-code", "codex"])
        XCTAssertEqual(g.cells["claude-code"], [0, 0, 1, 0, 1])
        XCTAssertEqual(g.cells["codex"], [0, 0, 0, 0, 1])
        XCTAssertEqual(g.maxCount, 1); XCTAssertEqual(g.total(onDay: 4), 2)
    }

    func testActivityIgnoresSessionsOutsideTheWindow() throws {
        try note("codex", "b1", title: "Old", project: "auth", updated: "2026-10-01T10:00:00Z")
        let g = VaultReader.activity(vault: vault, days: 5, now: now, calendar: utc)
        XCTAssertEqual(g.agents, []); XCTAssertEqual(g.maxCount, 0); XCTAssertEqual(g.days.count, 5)
    }

    func testProjectsAggregateAndSortByTurns() throws {
        try note("claude-code", "a1", title: "x", project: "notch", updated: "2026-11-14T10:00:00Z", turns: 10)
        try note("codex", "b1", title: "y", project: "notch", updated: "2026-11-13T10:00:00Z", turns: 5)
        try note("codex", "b2", title: "z", project: "auth", updated: "2026-11-12T10:00:00Z", turns: 20)
        try note("gemini", "c1", title: "w", project: "", updated: "2026-11-12T10:00:00Z", turns: 1)
        let p = VaultReader.projects(vault: vault, limit: 3)
        XCTAssertEqual(p.map(\.name), ["auth", "notch", "misc"])
        XCTAssertEqual(p[1], ProjectStat(name: "notch", sessions: 2, turns: 15))
        XCTAssertEqual(VaultReader.projects(vault: vault, limit: 1).count, 1)
    }

    func testSessionsOnADayListsStartedOrUpdatedThatDayNewestFirst() throws {
        try note("claude-code", "a1", title: "Long one", project: "notch", updated: "2026-11-14T10:00:00Z", started: "2026-11-12T09:00:00Z")
        try note("codex", "b1", title: "Later", project: "auth", updated: "2026-11-14T11:00:00Z")
        XCTAssertEqual(VaultReader.sessions(on: ISO8601DateFormatter().date(from: "2026-11-14T00:00:00Z")!, vault: vault, calendar: utc).map(\.lastTitle), ["Later", "Long one"])
        XCTAssertEqual(VaultReader.sessions(on: ISO8601DateFormatter().date(from: "2026-11-13T00:00:00Z")!, vault: vault, calendar: utc).count, 0)
        XCTAssertEqual(VaultReader.sessions(on: ISO8601DateFormatter().date(from: "2026-11-12T00:00:00Z")!, vault: vault, calendar: utc).map(\.lastTitle), ["Long one"])
    }
}
