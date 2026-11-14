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
    private func app(_ l: SettingsLoad) -> AppSettings? { if case .ok(let a) = l { return a }; return nil }

    func testLoadsHostAndModelWithDefaultsForTheRest() throws {
        try write(#"{"gemma":{"host":"ai.example.com","model":"gemma3:12b"}}"#)
        XCTAssertEqual(app(Settings.load(from: url))?.gemma, GemmaSettings(host: "ai.example.com", model: "gemma3:12b",
                                                                           keychainService: "ai.example.com", keychainAccount: "notchapp"))
    }
    func testKeychainOverrides() throws {
        try write(#"{"gemma":{"host":"ai.example.com","model":"m","keychain_service":"my-gateway","keychain_account":"me"}}"#)
        let g = app(Settings.load(from: url))?.gemma
        XCTAssertEqual(g?.keychainService, "my-gateway"); XCTAssertEqual(g?.keychainAccount, "me")
    }
    func testNoFileMeansDefaults() { XCTAssertEqual(Settings.load(from: url), .missing) }
    func testBrokenJSONIsReportedNotCrashed() throws {
        try write("{ nope")
        guard case .invalid(let why) = Settings.load(from: url) else { return XCTFail("expected invalid") }
        XCTAssertTrue(why.lowercased().contains("json"))
    }

    // Gemma is optional: a file with no gemma section is fine, and so is a blank template
    func testGemmaSectionIsOptional() throws {
        try write(#"{"default":"codex"}"#)
        let a = app(Settings.load(from: url))
        XCTAssertNil(a?.gemma); XCTAssertNil(a?.gemmaProblem); XCTAssertEqual(a?.defaultBackend, .codex)
    }
    func testBlankTemplateIsNotAProblem() throws {
        try write(#"{"default":"claude","gemma":{"host":"","model":""}}"#)
        let a = app(Settings.load(from: url))
        XCTAssertNil(a?.gemma); XCTAssertNil(a?.gemmaProblem)
    }
    func testHalfFilledGemmaIsReportedButDoesNotLoseTheRestOfTheFile() throws {
        try write(#"{"default":"codex","gemma":{"host":"ai.example.com"}}"#)
        let a = app(Settings.load(from: url))
        XCTAssertNil(a?.gemma); XCTAssertTrue(a?.gemmaProblem?.contains("model") == true); XCTAssertEqual(a?.defaultBackend, .codex)
        try write(#"{"gemma":{"model":"m"}}"#)
        XCTAssertTrue(app(Settings.load(from: url))?.gemmaProblem?.contains("host") == true)
    }
    func testInvalidHostInFileIsReported() throws {
        try write(#"{"gemma":{"host":"evil.com/x@ai.example.com","model":"m"}}"#)
        XCTAssertTrue(app(Settings.load(from: url))?.gemmaProblem?.contains("host") == true)
        XCTAssertNil(app(Settings.load(from: url))?.gemma)
    }
    func testDefaultMustBeARealModelName() throws {
        try write(#"{"default":"gpt-9000"}"#)
        XCTAssertNil(app(Settings.load(from: url))?.defaultBackend)
    }
    func testUnknownKeysAreIgnored() throws {
        try write(#"{"gemma":{"host":"h.example.com","model":"m","future":true},"extra":[1,2]}"#)
        XCTAssertNotNil(app(Settings.load(from: url))?.gemma)
    }

    // The bearer token is sent to whatever host is written here, so the host must be a plain hostname.
    func testHostNormalisation() {
        XCTAssertEqual(Settings.normalizeHost("ai.example.com"), "ai.example.com")
        XCTAssertEqual(Settings.normalizeHost("  https://ai.example.com/ "), "ai.example.com")
        XCTAssertEqual(Settings.normalizeHost("ai.example.com:8443"), "ai.example.com:8443")
        XCTAssertEqual(Settings.normalizeHost("localhost"), "localhost")
    }
    func testHostsThatCouldRedirectTheTokenAreRejected() {
        for bad in ["", "http://ai.example.com", "ai.example.com/path", "user@ai.example.com", "ai.example.com?x=1", "ai example.com",
                    "ai.example.com#frag", "-bad.example.com", "ai.example.com:99999x", "ai.example.com\n.evil.com", "https://a.com/../b"] {
            XCTAssertNil(Settings.normalizeHost(bad), "should reject: \(bad.debugDescription)")
        }
    }

    // "Set up Gemma…" opens a blank template; it must never clobber a real file
    func testTemplateIsCreatedOnceAndNeverOverwritten() throws {
        XCTAssertTrue(try Settings.ensureTemplate(at: url))
        let a = app(Settings.load(from: url)); XCTAssertNil(a?.gemma); XCTAssertNil(a?.gemmaProblem)   // blank, so not a problem
        try write(#"{"gemma":{"host":"mine.example.com","model":"m"}}"#)
        XCTAssertFalse(try Settings.ensureTemplate(at: url))
        XCTAssertEqual(app(Settings.load(from: url))?.gemma?.host, "mine.example.com")
    }
    func testTemplateCreatesMissingFoldersAndIsPrivate() throws {
        let nested = dir.appendingPathComponent("a/b/settings.json")
        XCTAssertTrue(try Settings.ensureTemplate(at: nested))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: nested.path)[.posixPermissions] as? Int, 0o600)
    }

    // MARK: workspace — where edit runs may write

    private let home = URL(fileURLWithPath: "/Users/me")
    private func norm(_ s: String, exists: Bool = true) -> String? { Settings.normalizeFolder(s, home: home) { _ in exists } }

    func testTildeAndAbsolutePathsInsideHomeAreAccepted() {
        XCTAssertEqual(norm("~/Projects"), "/Users/me/Projects")
        XCTAssertEqual(norm("/Users/me/Documents/work"), "/Users/me/Documents/work")
        XCTAssertEqual(norm("  ~/Desktop/  "), "/Users/me/Desktop")
        XCTAssertEqual(norm("~/Projects/./app/../app"), "/Users/me/Projects/app")      // normalised
    }
    func testHomeItselfAndEverythingOutsideItAreRefused() {
        for bad in ["~", "~/", "/Users/me", "/", "/Users", "/etc", "/System/Library", "/tmp", "/Users/someone-else/docs", "relative/dir", ""] {
            XCTAssertNil(norm(bad), "should refuse \(bad.debugDescription)")
        }
    }
    func testDotFoldersAndLibraryAreRefusedBecauseTheyHoldCredentials() {
        for bad in ["~/.ssh", "~/.aws/creds", "~/.config", "~/.gnupg", "~/Library", "~/Library/Keychains", "~/Projects/../.ssh"] {
            XCTAssertNil(norm(bad), "should refuse \(bad)")
        }
        XCTAssertEqual(norm("~/Projects/.hidden-but-nested"), "/Users/me/Projects/.hidden-but-nested")   // only the top level is guarded
    }
    func testDotDotCannotEscapeHome() {
        XCTAssertNil(norm("~/Projects/../../../etc")); XCTAssertNil(norm("~/../you/x"))
    }
    func testMissingFolderIsRefused() { XCTAssertNil(norm("~/Projects", exists: false)) }

    func testWorkspaceSectionParsesDefaultAndFolders() throws {
        let tmp = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches")   // exists, but is guarded, so use the temp dir under a fake home below
        _ = tmp
        try write(#"{"workspace":{"default":"~/Projects","folders":["~/Desktop","~/Downloads"]}}"#)
        let a = app(Settings.load(from: url, home: home, exists: { _ in true }))
        XCTAssertEqual(a?.workspaceDefault, "/Users/me/Projects")
        XCTAssertEqual(a?.folders, ["/Users/me/Desktop", "/Users/me/Downloads"])
        XCTAssertEqual(a?.workspaceProblems, [])
    }
    func testNoWorkspaceSectionMeansUseTheBuiltInList() throws {
        try write(#"{"default":"claude"}"#)
        let a = app(Settings.load(from: url, home: home, exists: { _ in true }))
        XCTAssertNil(a?.workspaceDefault); XCTAssertNil(a?.folders)
    }
    func testRejectedFoldersAreReportedAndTheRestKept() throws {
        try write(#"{"workspace":{"default":"~/.ssh","folders":["~/Desktop","/etc","~/Nope"]}}"#)
        let a = app(Settings.load(from: url, home: home, exists: { $0 != "/Users/me/Nope" }))
        XCTAssertNil(a?.workspaceDefault)
        XCTAssertEqual(a?.folders, ["/Users/me/Desktop"])
        XCTAssertEqual(a?.workspaceProblems.count, 3)
    }
    func testDuplicateFoldersCollapse() throws {
        try write(#"{"workspace":{"folders":["~/Desktop","~/Desktop/","/Users/me/Desktop"]}}"#)
        XCTAssertEqual(app(Settings.load(from: url, home: home, exists: { _ in true }))?.folders, ["/Users/me/Desktop"])
    }

    // MARK: the Settings window saves through this

    func testUpdateWritesOnlyWhatWasGivenAndKeepsUnknownKeys() throws {
        try write(#"{"future":{"x":1},"gemma":{"host":"h.example.com","model":"m"}}"#)
        try Settings.update(at: url, defaultBackend: .codex, workspaceDefault: "/Users/me/Projects", folders: ["/Users/me/Desktop"])
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        XCTAssertEqual(obj["default"] as? String, "codex")
        XCTAssertEqual((obj["workspace"] as? [String: Any])?["default"] as? String, "/Users/me/Projects")
        XCTAssertEqual((obj["workspace"] as? [String: Any])?["folders"] as? [String], ["/Users/me/Desktop"])
        XCTAssertNotNil(obj["future"]); XCTAssertEqual((obj["gemma"] as? [String: Any])?["host"] as? String, "h.example.com")
    }
    func testUpdateCanClearTheDefaultWorkspaceAndCreatesAPrivateFile() throws {
        let fresh = dir.appendingPathComponent("new/settings.json")
        try Settings.update(at: fresh, defaultBackend: nil, workspaceDefault: nil, folders: [])
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: fresh)) as! [String: Any]
        XCTAssertNil((obj["workspace"] as? [String: Any])?["default"])
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: fresh.path)[.posixPermissions] as? Int, 0o600)
    }
    func testUpdateWritesGemmaOnlyWhenAsked() throws {
        try Settings.update(at: url, defaultBackend: .claude, workspaceDefault: nil, folders: [],
                            gemma: .init(host: "ai.example.com", model: "gemma3:12b", keychainService: "ai.example.com", keychainAccount: "notchapp"))
        XCTAssertEqual(app(Settings.load(from: url))?.gemma?.model, "gemma3:12b")
    }
    func testUpdateCanRemoveTheGemmaSectionAndKeepTheRest() throws {
        try write(#"{"future":1,"gemma":{"host":"h.example.com","model":"m"}}"#)
        try Settings.update(at: url, defaultBackend: .claude, workspaceDefault: nil, folders: [], removeGemma: true)
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        XCTAssertNil(obj["gemma"]); XCTAssertNotNil(obj["future"])
    }
    func testUpdateRefusesToOverwriteAFileItCannotRead() throws {
        try write("{ hand-edited and broken")
        XCTAssertThrowsError(try Settings.update(at: url, defaultBackend: .claude, workspaceDefault: nil, folders: []))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "{ hand-edited and broken")      // untouched
    }

    func testEnvironmentOverrideMovesTheSettingsFile() {
        defer { unsetenv("NOTCH_SETTINGS") }
        setenv("NOTCH_SETTINGS", "/tmp/demo/settings.json", 1)
        XCTAssertEqual(Settings.defaultURL.path, "/tmp/demo/settings.json")
        setenv("NOTCH_SETTINGS", "", 1)
        XCTAssertTrue(Settings.defaultURL.path.hasSuffix("NotchApp/settings.json"))
    }
}
