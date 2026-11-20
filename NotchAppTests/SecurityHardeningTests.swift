import XCTest

final class ToolScopeTests: XCTestCase {
    private func list(_ a: [String], after flag: String) -> [String] {
        guard let i = a.firstIndex(of: flag) else { return [] }
        return Array(a[(i + 1)...].prefix { !$0.hasPrefix("--") })
    }
    private let scratch = "/Users/me/Library/Application Support/NotchApp/scratch"

    func testAskModeReadsOnlyTheScratchFolderNeverABareRead() {
        let a = AgentStream.claudeArgs(prompt: "x", session: nil, work: false, folder: "/Users/me/Desktop", scratch: scratch)
        let allowed = list(a, after: "--allowedTools")
        XCTAssertTrue(allowed.contains("Read(//Users/me/Library/Application Support/NotchApp/scratch/**)"))
        for bare in ["Read", "Grep", "Glob", "Edit", "Write", "Bash"] { XCTAssertFalse(allowed.contains(bare), bare) }
        XCTAssertFalse(allowed.contains { $0.contains("Desktop") })           // the chosen folder is for `+` runs only
        XCTAssertTrue(allowed.contains("WebSearch"))
    }
    func testSecretPlacesAreDeniedInBothModes() {
        for work in [false, true] {
            let denied = list(AgentStream.claudeArgs(prompt: "x", session: nil, work: work, scratch: scratch), after: "--disallowedTools")
            for p in ["~/.ssh", "~/.aws", "~/.config", "~/.gnupg", "~/Library/Keychains", "~/.netrc", "~/.claude.json", "~/.codex/auth.json"] {
                XCTAssertTrue(denied.contains("Read(\(p)/**)") || denied.contains("Read(\(p))"), "\(p) work=\(work)")
            }
            XCTAssertTrue(denied.contains("Read(~/.ssh/**)"))
        }
    }
    func testWorkModeScopesReadsAndEditsToScratchAndTheChosenFolder() {
        let a = AgentStream.claudeArgs(prompt: "x", session: nil, work: true, folder: "/Users/me/Desktop", scratch: scratch)
        let allowed = list(a, after: "--allowedTools")
        for t in ["Read", "Edit"] { XCTAssertTrue(allowed.contains("\(t)(//Users/me/Desktop/**)"), t); XCTAssertTrue(allowed.contains("\(t)(/\(scratch)/**)"), t) }
        XCTAssertFalse(allowed.contains("Read")); XCTAssertFalse(allowed.contains("Edit")); XCTAssertFalse(allowed.contains("Write"))
        XCTAssertFalse(allowed.contains("WebFetch")); XCTAssertFalse(allowed.contains("WebSearch"))      // nothing outside the sandbox can carry out what a shell read
    }
    func testYourOtherSettingsAndMCPToolsAreNotReachable() {
        for work in [false, true] {
            let a = AgentStream.claudeArgs(prompt: "x", session: nil, work: work, scratch: scratch)
            XCTAssertEqual(list(a, after: "--setting-sources"), ["project"]); XCTAssertTrue(a.contains("--strict-mcp-config"))
            XCTAssertFalse(list(a, after: "--allowedTools").contains("mcp__agentvault"))     // no server configured, so no tool either
        }
        let a = AgentStream.claudeArgs(prompt: "x", session: nil, work: false, scratch: scratch, mcpConfig: #"{"mcpServers":{"agentvault":{}}}"#)
        XCTAssertEqual(list(a, after: "--mcp-config").count, 1); XCTAssertTrue(list(a, after: "--allowedTools").contains("mcp__agentvault"))
        XCTAssertEqual(a.last, "x")
    }
    func testOnlyTheAgentvaultServerIsCopiedFromYourClaudeConfig() throws {
        let json = #"{"mcpServers":{"gmail":{"command":"send-mail"},"agentvault":{"command":"python3","args":["-m","agentvault.mcp_server"]}},"oauthAccount":{"x":1}}"#
        let out = try XCTUnwrap(AgentStream.agentvaultMCPConfig(claudeJSON: Data(json.utf8)))
        XCTAssertTrue(out.contains("agentvault")); XCTAssertFalse(out.contains("gmail")); XCTAssertFalse(out.contains("oauthAccount"))
        XCTAssertNil(AgentStream.agentvaultMCPConfig(claudeJSON: Data(#"{"mcpServers":{"gmail":{}}}"#.utf8)))
        XCTAssertNil(AgentStream.agentvaultMCPConfig(claudeJSON: nil)); XCTAssertNil(AgentStream.agentvaultMCPConfig(claudeJSON: Data("nope".utf8)))
    }
    func testTheWorkSandboxAlsoRefusesToReadSecrets() throws {
        let a = AgentStream.claudeArgs(prompt: "x", session: nil, work: true, scratch: scratch)
        let s = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(a[a.firstIndex(of: "--settings")! + 1].utf8)) as? [String: Any])
        let deny = (((s["sandbox"] as? [String: Any])?["filesystem"]) as? [String: Any])?["denyRead"] as? [String]
        XCTAssertTrue(deny?.contains("~/.ssh") ?? false)
        for p in ["~/.npmrc", "~/.git-credentials", "~/.docker", "~/.kube", "~/.zsh_history", "~/.bash_history", "~/Library/Messages", "~/Library/Mail", "~/Library/Cookies", "~/Library/Safari",
                  "~/Library/Application Support/Google/Chrome", "~/Library/Application Support/BraveSoftware", "~/.config/gh", "~/.pypirc", "~/.cargo/credentials", "~/.cargo/credentials.toml"] {
            XCTAssertTrue(deny?.contains(p) ?? false, p)
        }
    }
    func testCodexPromptsAreAfterDoubleDashEvenWhenTheyLookLikeFlags() {
        for work in [false, true] {
            let a = AgentStream.codexArgs(prompt: "--sandbox danger-full-access", session: nil, work: work)
            XCTAssertEqual(Array(a.suffix(2)), ["--", "--sandbox danger-full-access"])
        }
    }
    func testTriageCodexConfigHasNoMCPServers() {
        XCTAssertFalse(AgentStream.codexTriageConfig.contains("mcp_servers")); XCTAssertTrue(AgentStream.codexTriageConfig.hasPrefix("#"))
    }
}

final class RunSpaceTests: XCTestCase {
    private func tmp() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("rs-" + UUID().uuidString); try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: u) }; return u
    }
    func testScrubRemovesPlantedSettingsAndLeavesUserFiles() throws {
        let d = try tmp(), fm = FileManager.default
        try fm.createDirectory(at: d.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try "{}".write(to: d.appendingPathComponent(".claude/settings.json"), atomically: true, encoding: .utf8)
        try "{}".write(to: d.appendingPathComponent(".mcp.json"), atomically: true, encoding: .utf8)
        try "obey".write(to: d.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: d.appendingPathComponent("AGENTS.md"), withDestinationURL: URL(fileURLWithPath: "/nonexistent/target"))   // dangling link
        try "keep".write(to: d.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        XCTAssertEqual(Set(RunSpace.scrub(d)), [".claude", ".mcp.json", "CLAUDE.md", "AGENTS.md"])
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: d.path), ["notes.txt"])
        XCTAssertTrue(RunSpace.scrub(d).isEmpty)
    }
    func testScrubRemovesEverySymlinkAndNestedPlantedFilesWithoutFollowingThem() throws {
        let d = try tmp(), outside = try tmp(), fm = FileManager.default
        try "secret".write(to: outside.appendingPathComponent("target.txt"), atomically: true, encoding: .utf8)
        try fm.createDirectory(at: d.appendingPathComponent("a/b/.claude"), withIntermediateDirectories: true)
        try "{}".write(to: d.appendingPathComponent("a/b/.claude/settings.json"), atomically: true, encoding: .utf8)
        try "obey".write(to: d.appendingPathComponent("a/CLAUDE.md"), atomically: true, encoding: .utf8)
        try "obey".write(to: d.appendingPathComponent("a/b/AGENTS.md"), atomically: true, encoding: .utf8)
        try "keep".write(to: d.appendingPathComponent("a/b/notes.txt"), atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: d.appendingPathComponent("a/link.txt"), withDestinationURL: outside.appendingPathComponent("target.txt"))
        try fm.createSymbolicLink(at: d.appendingPathComponent("dirlink"), withDestinationURL: outside)       // a link to a folder: removed, not entered
        try fm.createSymbolicLink(at: d.appendingPathComponent("a/b/dangling"), withDestinationURL: URL(fileURLWithPath: "/nonexistent"))
        XCTAssertEqual(Set(RunSpace.scrub(d)), ["a/b/.claude", "a/CLAUDE.md", "a/b/AGENTS.md", "a/link.txt", "dirlink", "a/b/dangling"])
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: d.appendingPathComponent("a/b").path), ["notes.txt"])
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: outside.path), ["target.txt"])       // nothing outside was touched
        XCTAssertTrue(RunSpace.scrub(d).isEmpty)
    }
    func testEveryLockedRunGetsANewEmptyFolder() throws {
        let a = try RunSpace.freshRunDir(), b = try RunSpace.freshRunDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: a.path), [])
    }
    func testCodexTriageHomeHasAnEmptyConfigAndOnlyALinkToTheSignIn() throws {
        let real = try tmp(); try "tok".write(to: real.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)
        try "[mcp_servers.gmail]\ncommand=\"x\"\n".write(to: real.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        let h = try RunSpace.codexTriageHome(realHome: real); addTeardownBlock { try? FileManager.default.removeItem(at: h) }
        XCTAssertNotEqual(h, real)
        XCTAssertFalse(try String(contentsOf: h.appendingPathComponent("config.toml"), encoding: .utf8).contains("mcp_servers"))
        XCTAssertEqual(try String(contentsOf: h.appendingPathComponent("auth.json"), encoding: .utf8), "tok")
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: h.path)), ["config.toml", "auth.json"])
    }
    func testCodexTriageWithoutAFileLoginFailsSoAnotherModelIsUsed() throws {
        XCTAssertThrowsError(try RunSpace.codexTriageHome(realHome: try tmp()))
    }
    func testARefreshedCodexTokenIsKeptButAnUntouchedLinkIsNot() throws {
        let real = try tmp(); try "old".write(to: real.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)
        let h = try RunSpace.codexTriageHome(realHome: real); addTeardownBlock { try? FileManager.default.removeItem(at: h) }
        RunSpace.keepRefreshedAuth(from: h, to: real)
        XCTAssertEqual(try String(contentsOf: real.appendingPathComponent("auth.json"), encoding: .utf8), "old")
        try FileManager.default.removeItem(at: h.appendingPathComponent("auth.json"))
        try "new".write(to: h.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)         // what a token refresh does
        RunSpace.keepRefreshedAuth(from: h, to: real)
        XCTAssertEqual(try String(contentsOf: real.appendingPathComponent("auth.json"), encoding: .utf8), "new")
    }
}

final class AnswerLinkTests: XCTestCase {
    private func md(_ s: String) -> AttributedString {
        RunSpace.safeLinks(try! AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
    }
    func testWebLinksStayClickableAndShowWhereTheyGo() {
        let a = md("[Sign in](https://evil.example/login)")
        XCTAssertEqual(String(a.characters), "Sign in (evil.example)")
        XCTAssertEqual(a.runs.compactMap(\.link).map(\.absoluteString), ["https://evil.example/login"])
        XCTAssertFalse(a.runs.contains { $0.link != nil && String(a[$0.range].characters).contains("evil.example") })   // the host tag itself is not a link
    }
    func testALabelThatIsAnotherSiteStillShowsTheRealHost() {
        XCTAssertEqual(String(md("[https://paypal.com](https://evil.example/x)").characters), "https://paypal.com (evil.example)")
    }
    func testOtherSchemesBecomePlainText() {
        for u in ["javascript:alert(1)", "file:///Users/me/.ssh/id_rsa", "x-apple.systempreferences:com.apple.preference", "vscode://x", "mailto:a@b.com", "tel:123"] {
            let a = md("[tap](\(u))")
            XCTAssertEqual(String(a.characters), "tap", u); XCTAssertTrue(a.runs.allSatisfy { $0.link == nil }, u)
        }
    }
    func testPlainProseIsUntouched() { XCTAssertEqual(String(md("just **words**").characters), "just words") }
}

final class ReplyRecipientTests: XCTestCase {
    private func ctx(from: String, replyTo: String = "") -> MailContext {
        MailContext(account: "me@home.com", id: "m", threadId: "t", from: from, replyTo: replyTo, subject: "Hi", messageID: "<a@b>", references: "", date: nil, body: "x")
    }
    private func to(_ c: MailContext) -> String? {
        guard let raw = MailReply.raw(c, body: "ok") else { return nil }
        var t = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/"); while t.count % 4 != 0 { t += "=" }
        let msg = String(decoding: Data(base64Encoded: t) ?? Data(), as: UTF8.self)
        return msg.components(separatedBy: "\r\n").first { $0.hasPrefix("To: ") }.map { String($0.dropFirst(4)) }
    }

    func testAReplyGoesToExactlyOneBareAddress() {
        XCTAssertEqual(to(ctx(from: "Priya Nair <p@corp.example>")), "p@corp.example")
        XCTAssertEqual(to(ctx(from: "Priya <p@corp.example>", replyTo: "Desk <desk@corp.example>")), "desk@corp.example")
        XCTAssertEqual(MailReply.recipient(ctx(from: "Priya Nair <p@corp.example>")), "Priya Nair <p@corp.example>")     // the screen shows the whole address
    }
    func testAListInReplyToIsRefusedAndTheSenderIsUsed() {
        for bad in ["a@x.io, evil@y.io", "a@x.io; evil@y.io", "Desk <a@x.io>, evil@y.io", "evil@y.io, Desk <a@x.io>", "a@x.io evil@y.io", "<a@x.io><b@y.io>"] {
            XCTAssertEqual(to(ctx(from: "Priya <p@corp.example>", replyTo: bad)), "p@corp.example", bad)
        }
    }
    func testAListInFromMeansNoReply() {
        for bad in ["a@x.io, evil@y.io", "Priya <p@corp.example>; evil@y.io", "evil@y.io <p@corp.example>", "\"a@x.io\" \"b@y.io\" <c@z.io>, d@w.io", "no address here", ""] {
            XCTAssertNil(to(ctx(from: bad)), bad); XCTAssertNil(MailReply.recipient(ctx(from: bad)), bad)
        }
        XCTAssertNil(to(ctx(from: "a@x.io, b@y.io", replyTo: "c@z.io, d@w.io")))
    }
    func testQuotedNamesMayHoldCommasAndAtSigns() {
        XCTAssertEqual(to(ctx(from: "\"Nair, Priya\" <p@corp.example>")), "p@corp.example")
        XCTAssertEqual(MailReply.recipient(ctx(from: "\"Nair, Priya\" <p@corp.example>")), "Nair, Priya <p@corp.example>")
        XCTAssertEqual(to(ctx(from: "\"ceo@bank.com\" <p@corp.example>")), "p@corp.example")        // the real address is what is used, and shown
    }
    func testHeaderInjectionCannotAddRecipients() {
        XCTAssertEqual(to(ctx(from: "Priya <p@corp.example>", replyTo: "a@x.io\r\nBcc: evil@y.io")), "p@corp.example")
        let raw = MailReply.raw(ctx(from: "p@corp.example\nBcc: evil@y.io"), body: "ok")
        XCTAssertNil(raw)       // newline folded to a space leaves two @ outside quotes
    }
}
