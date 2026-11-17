import XCTest

final class AgentFilesTests: XCTestCase {
    func testAddingKeepsEverythingElseAndAddsOnce() {
        let mine = "# My rules\n\n- be brief\n"
        let once = AgentFiles.adding(to: mine)
        XCTAssertTrue(once.hasPrefix(mine)); XCTAssertTrue(AgentFiles.has(once)); XCTAssertTrue(once.hasSuffix("\n"))
        XCTAssertEqual(AgentFiles.adding(to: once), once)                       // pressing it twice changes nothing
        XCTAssertEqual(once.components(separatedBy: AgentFiles.begin).count, 2)
    }
    func testRemovingGivesBackTheOriginal() {
        for mine in ["# My rules\n\n- be brief\n", "no newline at the end", "", "a\n\n"] {
            XCTAssertEqual(AgentFiles.removing(from: AgentFiles.adding(to: mine)).trimmingCharacters(in: .whitespacesAndNewlines), mine.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        XCTAssertEqual(AgentFiles.removing(from: "untouched"), "untouched")
    }
    func testAnOlderCopyIsReplacedInPlaceAndLaterTextSurvives() {
        let old = "top\n\n\(AgentFiles.begin)\nold words\n\(AgentFiles.end)\n\nbottom\n"
        let new = AgentFiles.adding(to: old)
        XCTAssertFalse(new.contains("old words")); XCTAssertTrue(new.hasPrefix("top\n\n")); XCTAssertTrue(new.hasSuffix("bottom\n")); XCTAssertEqual(new.components(separatedBy: AgentFiles.begin).count, 2)
    }
    func testTheFileOnDiskIsBackedUpOnceAndRestoredOnRemove() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("agentfiles-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let t = AgentFiles.targets[0], file = home.appendingPathComponent(t.file)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "my private rules\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertTrue(AgentFiles.installed(t, home: home)); XCTAssertFalse(AgentFiles.enabled(t, home: home))
        try AgentFiles.set(true, t, home: home); try AgentFiles.set(true, t, home: home)
        XCTAssertTrue(AgentFiles.enabled(t, home: home))
        XCTAssertEqual(try String(contentsOf: file.appendingPathExtension("dex-backup"), encoding: .utf8), "my private rules\n")
        try AgentFiles.set(false, t, home: home)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "my private rules")
        XCTAssertFalse(AgentFiles.installed(AgentFiles.targets[1], home: home))     // Codex isn't installed: nothing is created for it
    }
}
