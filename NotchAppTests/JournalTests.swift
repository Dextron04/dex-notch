import XCTest

final class JournalTests: XCTestCase {
    private var dir: URL!
    override func setUpWithError() throws { dir = FileManager.default.temporaryDirectory.appendingPathComponent("journal-" + UUID().uuidString) }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func lines(_ conv: String) throws -> [[String: Any]] {
        try String(contentsOf: dir.appendingPathComponent(conv + ".jsonl"), encoding: .utf8)
            .split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
    }

    func testWritesOneJSONObjectPerEntryWithTheRecorderContract() throws {
        try Journal.append([JournalEntry(role: "user", text: "q", ts: t0), JournalEntry(role: "assistant", text: "a", ts: t0.addingTimeInterval(4))],
                           conv: "c1", model: "gemma", to: dir)
        let l = try lines("c1")
        XCTAssertEqual(l.count, 2)
        XCTAssertEqual(l[0]["role"] as? String, "user"); XCTAssertEqual(l[0]["text"] as? String, "q")
        XCTAssertEqual(l[0]["conv"] as? String, "c1");   XCTAssertEqual(l[0]["model"] as? String, "gemma"); XCTAssertEqual(l[0]["v"] as? Int, 1)
        XCTAssertEqual(l[0]["ts"] as? String, "2027-01-15T08:00:00Z"); XCTAssertEqual(l[1]["ts"] as? String, "2027-01-15T08:00:04Z")
    }
    func testAppendsInsteadOfOverwriting() throws {
        try Journal.append([JournalEntry(role: "user", text: "q1", ts: t0)], conv: "c1", model: "gemma", to: dir)
        try Journal.append([JournalEntry(role: "user", text: "q2", ts: t0)], conv: "c1", model: "gemma", to: dir)
        XCTAssertEqual(try lines("c1").map { $0["text"] as? String }, ["q1", "q2"])
    }
    func testNewlinesQuotesAndUnicodeStayOnOneLine() throws {
        let nasty = "line1\nline2 \"quoted\" \\ tab\t émoji 🙂 ```code```"
        try Journal.append([JournalEntry(role: "assistant", text: nasty, ts: t0)], conv: "c1", model: "gemma", to: dir)
        let raw = try String(contentsOf: dir.appendingPathComponent("c1.jsonl"), encoding: .utf8)
        XCTAssertEqual(raw.filter { $0 == "\n" }.count, 1)           // only the terminator
        XCTAssertEqual(try lines("c1")[0]["text"] as? String, nasty)  // and it round-trips exactly
    }
    func testEachConversationGetsItsOwnFile() throws {
        try Journal.append([JournalEntry(role: "user", text: "a", ts: t0)], conv: "c1", model: "gemma", to: dir)
        try Journal.append([JournalEntry(role: "user", text: "b", ts: t0)], conv: "c2", model: "gemma", to: dir)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(), ["c1.jsonl", "c2.jsonl"])
    }
    func testFileIsPrivate() throws {
        try Journal.append([JournalEntry(role: "user", text: "a", ts: t0)], conv: "c1", model: "gemma", to: dir)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("c1.jsonl").path)[.posixPermissions] as? Int, 0o600)
    }
    func testNothingToWriteCreatesNothing() throws {
        try Journal.append([], conv: "c1", model: "gemma", to: dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }
    func testConversationIdCannotEscapeTheJournalDirectory() throws {
        try Journal.append([JournalEntry(role: "user", text: "a", ts: t0)], conv: "../../evil", model: "gemma", to: dir)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.deletingLastPathComponent().appendingPathComponent("evil.jsonl").path))
    }
}
