import XCTest

final class ConversationStoreTests: XCTestCase {
    private var dir: URL!
    private var url: URL { dir.appendingPathComponent("conversation.json") }
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("conv-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func sample(closed: TimeInterval = -60) -> SavedConversation {
        SavedConversation(turns: [SavedTurn(role: "user", text: "hi"), SavedTurn(role: "assistant", text: "hello")],
                          backend: .claude, work: true, sessions: ["claude": "sid-1"], draft: "half a thought",
                          recalled: ["A note"], closedAt: now.addingTimeInterval(closed))
    }

    func testRoundTrip() throws {
        try ConversationStore.save(sample(), to: url)
        XCTAssertEqual(ConversationStore.load(from: url, now: now), sample())
    }
    func testFileIsPrivate() throws {
        try ConversationStore.save(sample(), to: url)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o600)
    }
    func testMissingFileIsNil() { XCTAssertNil(ConversationStore.load(from: url, now: now)) }
    func testCorruptFileIsNilNotACrash() throws {
        try Data("{ not json".utf8).write(to: url)
        XCTAssertNil(ConversationStore.load(from: url, now: now))
    }
    func testUnknownVersionIsIgnored() throws {
        var c = sample(); c.version = 99
        try ConversationStore.save(c, to: url)
        XCTAssertNil(ConversationStore.load(from: url, now: now))
    }
    func testStaleConversationStartsFreshAndFileIsRemoved() throws {
        try ConversationStore.save(sample(closed: -3600), to: url)
        XCTAssertNil(ConversationStore.load(from: url, now: now))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
    func testInterruptedAnswerIsDroppedOnLoad() throws {
        var c = sample(); c.turns.append(SavedTurn(role: "user", text: "q2")); c.turns.append(SavedTurn(role: "assistant", text: ""))
        try ConversationStore.save(c, to: url)
        XCTAssertEqual(ConversationStore.load(from: url, now: now)?.turns.last, SavedTurn(role: "user", text: "q2")) // question kept, empty answer gone
    }
    func testSaveLeavesNoTempFilesBehind() throws {
        try ConversationStore.save(sample(), to: url); try ConversationStore.save(sample(), to: url)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["conversation.json"])
    }
    func testClearRemovesTheFile() throws {
        try ConversationStore.save(sample(), to: url); ConversationStore.clear(url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
    func testAnEmptyConversationIsNotWorthKeeping() throws {
        try ConversationStore.save(SavedConversation(), to: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
