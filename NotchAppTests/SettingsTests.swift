import XCTest

final class SettingsTests: XCTestCase {
    private var dir: URL!
    private var url: URL { dir.appendingPathComponent("settings.json") }
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("settings-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }
    private func write(_ s: String) throws { try Data(s.utf8).write(to: url) }

    func testLoadsHostAndModelWithDefaultsForTheRest() throws {
        try write(#"{"gemma":{"host":"ai.example.com","model":"gemma3:12b"}}"#)
        XCTAssertEqual(Settings.load(from: url), .ok(GemmaSettings(host: "ai.example.com", model: "gemma3:12b",
                                                                   keychainService: "ai.example.com", keychainAccount: "notchapp")))
    }
    func testKeychainOverrides() throws {
        try write(#"{"gemma":{"host":"ai.example.com","model":"m","keychain_service":"my-gateway","keychain_account":"me"}}"#)
        guard case .ok(let g) = Settings.load(from: url) else { return XCTFail("expected ok") }
        XCTAssertEqual(g.keychainService, "my-gateway"); XCTAssertEqual(g.keychainAccount, "me")
    }
    func testMissingFileMeansNotConfigured() { XCTAssertEqual(Settings.load(from: url), .missing) }
    func testBrokenJSONIsReportedNotCrashed() throws {
        try write("{ nope")
        guard case .invalid(let why) = Settings.load(from: url) else { return XCTFail("expected invalid") }
        XCTAssertTrue(why.lowercased().contains("json"))
    }
    func testModelIsRequiredBecauseThereIsNoDefault() throws {
        try write(#"{"gemma":{"host":"ai.example.com"}}"#)
        guard case .invalid(let why) = Settings.load(from: url) else { return XCTFail("expected invalid") }
        XCTAssertTrue(why.contains("model"))
    }
    func testHostIsRequired() throws {
        try write(#"{"gemma":{"model":"m"}}"#)
        guard case .invalid(let why) = Settings.load(from: url) else { return XCTFail("expected invalid") }
        XCTAssertTrue(why.contains("host"))
    }
    func testMissingGemmaSectionIsInvalid() throws {
        try write(#"{"other":1}"#)
        guard case .invalid = Settings.load(from: url) else { return XCTFail("expected invalid") }
    }
    func testUnknownKeysAreIgnored() throws {
        try write(#"{"gemma":{"host":"h.example.com","model":"m","future":true},"extra":[1,2]}"#)
        guard case .ok = Settings.load(from: url) else { return XCTFail("expected ok") }
    }

    // The bearer token is sent to whatever host is written here, so the host must be a plain hostname.
    func testHostNormalisation() {
        XCTAssertEqual(Settings.normalizeHost("ai.example.com"), "ai.example.com")
        XCTAssertEqual(Settings.normalizeHost("  https://ai.example.com/ "), "ai.example.com")   // pasted URL
        XCTAssertEqual(Settings.normalizeHost("ai.example.com:8443"), "ai.example.com:8443")
        XCTAssertEqual(Settings.normalizeHost("localhost"), "localhost")
    }
    func testHostsThatCouldRedirectTheTokenAreRejected() {
        for bad in ["", "http://ai.example.com", "ai.example.com/path", "user@ai.example.com", "ai.example.com?x=1", "ai example.com",
                    "ai.example.com#frag", "-bad.example.com", "ai.example.com:99999x", "ai.example.com\n.evil.com", "https://a.com/../b"] {
            XCTAssertNil(Settings.normalizeHost(bad), "should reject: \(bad.debugDescription)")
        }
    }
    func testInvalidHostInFileIsReported() throws {
        try write(#"{"gemma":{"host":"evil.com/x@ai.example.com","model":"m"}}"#)
        guard case .invalid(let why) = Settings.load(from: url) else { return XCTFail("expected invalid") }
        XCTAssertTrue(why.contains("host"))
    }
}
