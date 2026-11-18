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
}
