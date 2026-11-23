import XCTest

final class HistoryStoreTests: XCTestCase {
    private var dir: URL!
    override func setUpWithError() throws { dir = FileManager.default.temporaryDirectory.appendingPathComponent("history-" + UUID().uuidString) }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func conv(_ id: String, _ q: String = "hello", ago: TimeInterval = 0, a: String = "hi") -> SavedConversation {
        SavedConversation(id: id, turns: [SavedTurn(role: "user", text: q), SavedTurn(role: "assistant", text: a)], updatedAt: now.addingTimeInterval(-ago))
    }

    func testSaveLoadRoundTripsAndSetsTitle() throws {
        var c = conv("c1", "  what is\n a monad?  ")
        c.sessions = ["claude": "sess-1"]; c.vaultTurns = 2
        try HistoryStore.save(c, in: dir)
        let back = try XCTUnwrap(HistoryStore.load("c1", in: dir))
        XCTAssertEqual(back.turns, c.turns); XCTAssertEqual(back.sessions, ["claude": "sess-1"]); XCTAssertEqual(back.vaultTurns, 2)
        XCTAssertEqual(back.title, "what is a monad?")
    }
    func testLongTitleIsOneLineOfAboutSixtyCharacters() {
        let t = HistoryStore.title([SavedTurn(role: "user", text: String(repeating: "word ", count: 40))])
        XCTAssertLessThanOrEqual(t.count, 60); XCTAssertTrue(t.hasSuffix("…")); XCTAssertFalse(t.contains("\n"))
    }
    func testListIsNewestActivityFirstAndSkipsDamagedFiles() throws {
        try HistoryStore.save(conv("old", ago: 9000), in: dir)
        try HistoryStore.save(conv("new", ago: 10), in: dir)
        try HistoryStore.save(conv("mid", ago: 500), in: dir)
        try Data("{ not json".utf8).write(to: dir.appendingPathComponent("broken.json"))
        try Data("x".utf8).write(to: dir.appendingPathComponent(".conversation-1.tmp"))
        XCTAssertEqual(HistoryStore.list(in: dir).map(\.id), ["new", "mid", "old"])
    }
    func testDeleteRemovesOnlyThatConversation() throws {
        try HistoryStore.save(conv("a"), in: dir); try HistoryStore.save(conv("b"), in: dir)
        HistoryStore.delete("a", in: dir)
        XCTAssertNil(HistoryStore.load("a", in: dir)); XCTAssertNotNil(HistoryStore.load("b", in: dir))
    }
    func testEmptyConversationIsNotKept() throws {
        try HistoryStore.save(SavedConversation(id: "e", draft: "typing"), in: dir)
        XCTAssertTrue(HistoryStore.list(in: dir).isEmpty)
    }
    func testIdCannotEscapeTheHistoryFolder() throws {
        try HistoryStore.save(conv("../../evil"), in: dir)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["______evil.json"])
        XCTAssertNotNil(HistoryStore.load("../../evil", in: dir))
    }
    func testFilesAndFolderArePrivate() throws {
        try HistoryStore.save(conv("c1"), in: dir)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int, 0o700)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: HistoryStore.fileURL("c1", in: dir).path)[.posixPermissions] as? Int, 0o600)
    }
    func testOldSavesWithoutTheNewFieldsStillDecodeAndNeverGoStale() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let old = #"{"version":1,"id":"o1","turns":[{"role":"user","text":"q"},{"role":"assistant","text":"a"}],"backend":"claude","work":false,"sessions":{},"draft":"","recalled":[],"closedAt":"2020-01-01T00:00:00Z"}"#
        try Data(old.utf8).write(to: HistoryStore.fileURL("o1", in: dir))
        let c = try XCTUnwrap(HistoryStore.list(in: dir).first)
        XCTAssertNil(c.title); XCTAssertNil(c.vaultTurns); XCTAssertEqual(HistoryStore.title(c.turns), "q")
        XCTAssertEqual(c.activity, ISO8601DateFormatter().date(from: "2020-01-01T00:00:00Z"))
    }
    func testGroupsByDay() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let noon = ISO8601DateFormatter().date(from: "2027-01-15T12:00:00Z")!
        func c(_ id: String, daysAgo: Double) -> SavedConversation { conv(id, ago: 0).with(noon.addingTimeInterval(-daysAgo * 86400)) }
        let g = HistoryStore.grouped([c("a", daysAgo: 0), c("b", daysAgo: 1), c("c", daysAgo: 3), c("d", daysAgo: 30)], now: noon, calendar: cal)
        XCTAssertEqual(g.map(\.label), ["Today", "Yesterday", "Previous 7 days", "Older"])
    }
    func testSearchMatchesTitleAndAnyMessage() {
        let c = conv("c", "plan a trip", a: "Try Lisbon in spring")
        XCTAssertTrue(HistoryStore.matches(c, "TRIP")); XCTAssertTrue(HistoryStore.matches(c, "lisbon")); XCTAssertTrue(HistoryStore.matches(c, " "))
        XCTAssertFalse(HistoryStore.matches(c, "tokyo"))
    }
}

private extension SavedConversation { func with(_ d: Date) -> SavedConversation { var c = self; c.updatedAt = d; return c } }
