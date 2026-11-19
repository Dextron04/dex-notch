import XCTest

final class RecorderTests: XCTestCase {
    private let mem = "/Users/a/Library/Application Support/Dex Notch/memory"

    func testThePlistRunsThePackageFromTheAppsFolderAndEscapesPaths() {
        let p = RecorderLogic.plist(python: "/usr/bin/python3", memoryDir: mem, vault: "/Users/a&b/Vault")
        XCTAssertTrue(p.contains("<key>WorkingDirectory</key><string>\(mem)</string>")); XCTAssertTrue(p.contains("<string>agentvault</string><string>run</string>"))
        XCTAssertTrue(p.contains("/Users/a&amp;b/Vault")); XCTAssertFalse(p.contains("a&b"))
        XCTAssertTrue(p.contains("<key>KeepAlive</key><true/>"))
        XCTAssertNotNil(try? PropertyListSerialization.propertyList(from: Data(p.utf8), format: nil))     // it is a valid property list
    }
    func testStatus() {
        let ours = RecorderLogic.plist(python: "/usr/bin/python3", memoryDir: mem, vault: "/v")
        XCTAssertEqual(RecorderLogic.status(plistText: nil, memoryDir: mem, running: false, python: true), .notInstalled)
        XCTAssertEqual(RecorderLogic.status(plistText: nil, memoryDir: mem, running: false, python: false), .needsPython)
        XCTAssertEqual(RecorderLogic.status(plistText: ours, memoryDir: mem, running: true, python: true), .running)
        XCTAssertEqual(RecorderLogic.status(plistText: ours, memoryDir: mem, running: false, python: true), .stopped)
    }
    func testADevelopersOwnRecorderIsLeftAlone() {
        let theirs = RecorderLogic.plist(python: "/opt/homebrew/bin/python3", memoryDir: "/Users/a/Projects/dex-notch/memory", vault: "/v")
        XCTAssertEqual(RecorderLogic.status(plistText: theirs, memoryDir: mem, running: true, python: true), .elsewhere("/Users/a/Projects/dex-notch/memory"))
    }
    func testAnUpdatedAppRefreshesTheCopy() {
        XCTAssertTrue(RecorderLogic.needsUpdate(installed: "0.9.0", app: "0.9.1")); XCTAssertTrue(RecorderLogic.needsUpdate(installed: nil, app: "0.9.1")); XCTAssertFalse(RecorderLogic.needsUpdate(installed: "0.9.1", app: "0.9.1"))
    }
    func testSwappingInAFreshRecorderKeepsTheOldOneIfTheCopyFails() throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("swap-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let src = root.appendingPathComponent("src"), dest = root.appendingPathComponent("agentvault")
        try fm.createDirectory(at: src, withIntermediateDirectories: true); try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        try "new".write(to: src.appendingPathComponent("a.py"), atomically: true, encoding: .utf8); try "old".write(to: dest.appendingPathComponent("a.py"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try RecorderLogic.swapIn(root.appendingPathComponent("missing"), to: dest))       // the copy fails ...
        XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("a.py")), "old")                        // ... and the old recorder is still there
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: root.path).sorted(), ["agentvault", "src"])             // no half-copy left behind
        try RecorderLogic.swapIn(src, to: dest)
        XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("a.py")), "new")
        try fm.removeItem(at: dest); try RecorderLogic.swapIn(src, to: dest)                                    // first install: nothing to replace
        XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("a.py")), "new")
    }
}
