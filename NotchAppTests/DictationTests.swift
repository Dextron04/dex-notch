import XCTest

final class DictationTests: XCTestCase {
    func testCleaned() {
        XCTAssertNil(DictationLogic.cleaned(""))
        XCTAssertNil(DictationLogic.cleaned(" \n\t "))
        XCTAssertEqual(DictationLogic.cleaned("  hello there \n"), "hello there")
    }

    func testRestoreOnlyIfClipboardUntouched() {
        XCTAssertTrue(DictationLogic.shouldRestore(setCount: 7, currentCount: 7))
        XCTAssertFalse(DictationLogic.shouldRestore(setCount: 7, currentCount: 8))
    }

    func testVoiceSettings() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertFalse(DictationLogic.voice(at: url).allowServer)           // no file: defaults
        try Data(#"{"voice":{"locale":"fr-FR","allow_apple_server":true}}"#.utf8).write(to: url)
        let v = DictationLogic.voice(at: url)
        XCTAssertEqual(v.locale.identifier, "fr-FR"); XCTAssertTrue(v.allowServer)
    }

    func testTapOrHold() {
        var k = TapOrHold()
        XCTAssertTrue(k.press()); XCTAssertFalse(k.press())            // autorepeat ignored
        XCTAssertEqual(k.release(), .tap)                              // released before the threshold
        XCTAssertEqual(k.release(), .ignored)
        XCTAssertTrue(k.press()); XCTAssertTrue(k.thresholdPassed()); XCTAssertFalse(k.thresholdPassed())
        XCTAssertEqual(k.release(), .endHold)
        XCTAssertFalse(k.thresholdPassed())                            // timer firing after release does nothing
    }
}
