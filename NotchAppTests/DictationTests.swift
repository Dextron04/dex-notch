import XCTest

final class DictationTests: XCTestCase {
    func testCleaned() {
        XCTAssertNil(DictationLogic.cleaned(""))
        XCTAssertNil(DictationLogic.cleaned(" \n\t "))
        XCTAssertEqual(DictationLogic.cleaned("  hello there \n"), "hello there")
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

    func testTapOrHoldHealsALostRelease() {
        var k = TapOrHold(), t = Date()
        XCTAssertTrue(k.press(at: t))
        XCTAssertFalse(k.press(at: t.addingTimeInterval(0.5)))         // autorepeat inside the window
        XCTAssertFalse(k.press(at: t.addingTimeInterval(2.0)))         // autorepeat keeps it alive (2 s after the last press, not the first)
        XCTAssertTrue(k.press(at: t.addingTimeInterval(5)))            // release was lost: a press after a long gap is fresh
        XCTAssertEqual(k.release(), .tap)
    }
}

final class VoiceSwitchTests: XCTestCase {
    func testEnabledDefaultsOnAndKeepsOtherKeys() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sw-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(DictationLogic.enabled(at: url))                       // no file
        try Data(#"{"voice":{"locale":"hi-IN"}}"#.utf8).write(to: url)
        XCTAssertTrue(DictationLogic.enabled(at: url))
        try DictationLogic.setEnabled(at: url, false)
        XCTAssertFalse(DictationLogic.enabled(at: url)); XCTAssertEqual(DictationLogic.stored(at: url).primary, "hi-IN")
        try DictationLogic.setEnabled(at: url, true)
        XCTAssertTrue(DictationLogic.enabled(at: url))
    }
}

final class DictationLanguageTests: XCTestCase {
    func testLanguagesPrimaryFirstDedupedMax3() {
        XCTAssertEqual(DictationLogic.languages(primary: "hi-IN", list: ["en-US", "hi_IN", "fr-FR", "de-DE"]), ["hi-IN", "en-US", "fr-FR"])
        XCTAssertEqual(DictationLogic.languages(primary: nil, list: ["", " en-us ", "EN-us"]), ["en-us"])
        XCTAssertEqual(DictationLogic.languages(primary: "en_US", list: []), ["en-US"])
    }

    func testNextWraps() {
        let l = ["en-US", "hi-IN", "fr-FR"]
        XCTAssertEqual(DictationLogic.next(after: "en-US", in: l), "hi-IN")
        XCTAssertEqual(DictationLogic.next(after: "fr-FR", in: l), "en-US")
        XCTAssertEqual(DictationLogic.next(after: "ja-JP", in: l), "en-US")
        XCTAssertNil(DictationLogic.next(after: "en-US", in: []))
        XCTAssertEqual(DictationLogic.code(for: "hi_IN"), "HI")
    }

    func testHinglish() throws {
        XCTAssertEqual(DictationLogic.normalized("mul_IN"), "mul-IN")
        XCTAssertEqual(DictationLogic.normalized("MUL-IN"), "mul-IN")
        XCTAssertEqual(DictationLogic.code(for: "mul_IN"), "HG")
        XCTAssertEqual(DictationLogic.normalized(Locale(identifier: "mul_IN").identifier(.bcp47)), "mul-IN")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lang-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try DictationLogic.save(at: url, languages: ["mul_IN", "en-US"])
        let s = DictationLogic.stored(at: url)
        XCTAssertEqual(s.primary, "mul-IN"); XCTAssertEqual(s.list, ["mul-IN", "en-US"])
    }

    func testStoredAndSaveKeepOtherKeys() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lang-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"default":"claude","voice":{"locale":"hi-IN","languages":["hi-IN","en-US","fr-FR"],"allow_apple_server":true}}"#.utf8).write(to: url)
        let s = DictationLogic.stored(at: url)
        XCTAssertEqual(s.primary, "hi-IN"); XCTAssertEqual(s.list, ["hi-IN", "en-US", "fr-FR"])
        try DictationLogic.setPrimary(at: url, "en-US")                       // cycling keeps the list order
        XCTAssertEqual(DictationLogic.stored(at: url).list, ["hi-IN", "en-US", "fr-FR"])
        XCTAssertEqual(DictationLogic.next(after: "en-US", in: DictationLogic.stored(at: url).list), "fr-FR")
        try DictationLogic.save(at: url, languages: ["fr-FR"])
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let v = root["voice"] as! [String: Any]
        XCTAssertEqual(root["default"] as? String, "claude"); XCTAssertEqual(v["locale"] as? String, "fr-FR")
        XCTAssertNil(v["languages"]); XCTAssertEqual(v["allow_apple_server"] as? Bool, true)
    }
}

final class VoiceDownloadTests: XCTestCase {
    func testQueueOrderAndNoDuplicates() {
        var q = DownloadQueue()
        q.add("hi-IN"); q.add("fr_FR"); q.add("HI-in")
        XCTAssertEqual(q.items, ["hi-IN", "fr_FR"]); XCTAssertTrue(q.contains("fr-FR"))
        XCTAssertEqual(q.pop(), "hi-IN"); q.remove("fr-FR")
        XCTAssertNil(q.pop())
    }

    func testDownloadMessageByDomainAndCode() {
        XCTAssertEqual(DictationLogic.downloadMessage(domain: NSURLErrorDomain, code: -1009, name: "Hindi"), "No internet connection. Try again when you're online.")
        XCTAssertEqual(DictationLogic.downloadMessage(domain: "SFSpeechErrorDomain", code: 7, name: "Hindi"), "Couldn't download Hindi (7). Try again.")
        XCTAssertEqual(DictationLogic.downloadMessage(domain: NSCocoaErrorDomain, code: -1009, name: "Hindi"), "Couldn't download Hindi (-1009). Try again.")
    }

    func testReserveDecision() {
        let keep: Set<String> = ["en-us", "hi-in"]
        XCTAssertEqual(DictationLogic.reserveDecision(reserved: ["en-US", "hi-IN"], keep: keep, wanted: "hi-IN", max: 2), .ok)       // already held
        XCTAssertEqual(DictationLogic.reserveDecision(reserved: ["en-US"], keep: keep, wanted: "hi-IN", max: 2), .ok)                 // room
        XCTAssertEqual(DictationLogic.reserveDecision(reserved: ["en-US", "fr-FR"], keep: keep, wanted: "hi-IN", max: 2), .release(["fr-FR"]))
        XCTAssertEqual(DictationLogic.reserveDecision(reserved: ["en-US", "hi-IN"], keep: keep, wanted: "ja-JP", max: 2), .full(2))
    }

    func testFallbackAndMacOS26List() {
        XCTAssertEqual(DictationLogic.fallback(for: "hi-IN", available: ["fr-FR", "en-US"]), "en-US")
        XCTAssertEqual(DictationLogic.fallback(for: "fr_FR", available: ["fr-FR", "en-US"]), "fr-FR")
        XCTAssertEqual(DictationLogic.fallback(for: "hi-IN", available: ["fr-FR", "en-GB"]), "en-GB")
        XCTAssertNil(DictationLogic.fallback(for: "hi-IN", available: []))
        XCTAssertTrue(DictationLogic.needsMacOS26("hi_IN")); XCTAssertTrue(DictationLogic.needsMacOS26("mul-IN")); XCTAssertFalse(DictationLogic.needsMacOS26("en-US"))
    }
}
