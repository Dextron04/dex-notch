import XCTest

final class AddonsTests: XCTestCase {
    private func mail(_ id: String, from: String = "Priya Nair <priya@acme.com>", labels: [String] = ["INBOX", "UNREAD"], bulk: Bool = false, age: TimeInterval = 0) -> MailItem {
        MailItem(id: id, threadId: "abc123" + id, from: from, subject: "Subject \(id)", snippet: "Snippet \(id)", date: Date(timeIntervalSince1970: 1_000_000 - age), labels: labels, bulk: bulk)
    }

    // MARK: names + cleaning

    func testAddressAndDisplayName() {
        XCTAssertEqual(Triage.address("Priya Nair <Priya@Acme.com>"), "priya@acme.com")
        XCTAssertEqual(Triage.address("bob@x.org"), "bob@x.org")
        XCTAssertEqual(Triage.displayName("\"Priya Nair\" <p@a.com>"), "Priya Nair")
        XCTAssertEqual(Triage.displayName("bob@x.org"), "bob")
    }
    func testCleanStripsControlsCollapsesAndTruncates() {
        XCTAssertEqual(Triage.clean("a\u{0007}  b\n\nc\u{200B}d", max: 50), "a b c d")
        XCTAssertEqual(Triage.clean(String(repeating: "x", count: 100), max: 10).count, 10)
        XCTAssertTrue(Triage.clean(String(repeating: "x", count: 100), max: 10).hasSuffix("…"))
    }

    // MARK: layer 1

    func testPrefilterDropsSeenMutedAndNoisyLabelsNewestFirst() {
        let items = [mail("1", age: 30), mail("2", labels: ["CATEGORY_PROMOTIONS"]), mail("3", labels: ["SPAM"]), mail("4", from: "x <muted@a.com>"),
                     mail("5"), mail("6", labels: ["CATEGORY_UPDATES"], age: 10)]
        let out = Triage.prefilter(items, seen: ["1"], muted: ["muted@a.com"])
        XCTAssertEqual(out.map(\.id), ["5", "6"])        // updates stay: delivery and payment mail lives there
    }
    func testPrefilterCapsTheBatch() {
        let items = (0..<60).map { mail("m\($0)", age: Double($0)) }
        XCTAssertEqual(Triage.prefilter(items, seen: [], muted: []).count, Triage.batch)
    }

    // MARK: layer 2

    func testPromptCarriesRulesImportanceAndUntrustedFence() {
        let p = Triage.prompt(items: [mail("1")], importance: "my landlord")
        XCTAssertTrue(p.system.contains("my landlord")); XCTAssertTrue(p.system.contains("untrusted"))
        XCTAssertTrue(p.user.hasPrefix("<mail>")); XCTAssertTrue(p.user.contains("\"id\":\"1\""))
    }
    func testParseKeepsOnlyHighScoresFromIdsWeSent() {
        let items = [mail("1"), mail("2"), mail("3")]
        let reply = #"Sure! [{"id":"1","score":9,"headline":"Interview moved","reason":"Needs a reply"},{"id":"2","score":4,"headline":"x","reason":"y"},{"id":"zzz","score":10,"headline":"x","reason":"y"},{"id":"3","score":7,"headline":"Rent due","reason":"Due today"}]"#
        let a = Triage.parse(reply, items: items)
        XCTAssertEqual(a?.map(\.id), ["1", "3"])
        XCTAssertEqual(a?.first?.sender, "Priya Nair")
        XCTAssertEqual(a?.first?.url, "https://mail.google.com/mail/u/0/#inbox/abc1231")
    }
    func testParseNeedsAReasonAndDedupesAndCapsAtThree() {
        let items = (1...6).map { mail("\($0)") }
        let rows = (1...6).map { #"{"id":"\#($0)","score":\#(10 - $0),"headline":"h","reason":"r"}"# } + [#"{"id":"1","score":9,"headline":"dup","reason":"dup"}"#, #"{"id":"2","score":9,"headline":"no reason"}"#]
        let a = Triage.parse("[" + rows.joined(separator: ",") + "]", items: items)
        XCTAssertEqual(a?.count, Triage.maxAlerts)
        XCTAssertEqual(a?.map(\.id), ["1", "2", "3"])
        XCTAssertEqual(a?.first?.headline, "h")           // first row for an id wins
    }
    func testParseDistinguishesNothingImportantFromGarbage() {
        XCTAssertEqual(Triage.parse("[]", items: [mail("1")])?.count, 0)
        XCTAssertNil(Triage.parse("I'm sorry, I can't help with that.", items: [mail("1")]))
        XCTAssertNil(Triage.parse("[not json]", items: [mail("1")]))
    }
    func testParseNeutralisesHostileText() {
        let reply = #"[{"id":"1","score":9,"headline":"<b>Click</b>\u0007 now","reason":"\#(String(repeating: "A", count: 400))"}]"#
        let a = Triage.parse(reply, items: [mail("1", from: "Evil <e@x.com>")])?.first
        XCTAssertFalse(a!.headline.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) })
        XCTAssertLessThanOrEqual(a!.reason.count, 110)
        XCTAssertTrue(a!.url.hasPrefix("https://mail.google.com/"))       // the link is built here, never taken from the model
    }

    // MARK: layer 3

    func testChainFallsThroughErrorsAndGarbage() async {
        let items = [mail("1")]
        let good = #"[{"id":"1","score":9,"headline":"h","reason":"r"}]"#
        struct Limit: Error {}
        var tried: [Backend] = []
        let out = await Triage.run(items: items, importance: "", order: [.claude, .codex, .gemma]) { b, _, _ in
            switch b { case .claude: throw Limit(); case .codex: return "no idea"; case .gemma: return good }
        }
        tried = [out?.backend].compactMap { $0 }
        XCTAssertEqual(tried, [.gemma]); XCTAssertEqual(out?.alerts.count, 1)
    }
    func testChainStopsAtFirstUsableAnswerAndReportsTotalFailure() async {
        let calls = Counter()
        let first = await Triage.run(items: [mail("1")], importance: "", order: [.claude, .codex]) { _, _, _ in await calls.bump(); return "[]" }
        XCTAssertEqual(first?.backend, .claude); let n = await calls.n; XCTAssertEqual(n, 1)
        let none = await Triage.run(items: [mail("1")], importance: "", order: [.claude]) { _, _, _ in throw CancellationError() }
        XCTAssertNil(none)
        let empty = await Triage.run(items: [mail("1")], importance: "", order: []) { _, _, _ in "[]" }
        XCTAssertNil(empty)
    }

    // MARK: state + settings

    func testStateScheduleAndSeenCap() {
        var s = AddonState()
        let now = Date(timeIntervalSince1970: 100_000)
        XCTAssertTrue(s.isDue(now: now, hours: 4))
        s.lastTry = now.addingTimeInterval(-3 * 3600); s.lastOK = true
        XCTAssertFalse(s.isDue(now: now, hours: 4))
        s.lastTry = now.addingTimeInterval(-3601 * 4); XCTAssertTrue(s.isDue(now: now, hours: 4))
        s.lastTry = now.addingTimeInterval(-31 * 60); s.lastOK = false; XCTAssertTrue(s.isDue(now: now, hours: 4))     // failed: retry in 30 min
        s.lastTry = now.addingTimeInterval(-10 * 60); XCTAssertFalse(s.isDue(now: now, hours: 4))
        s.markSeen((0..<(AddonState.maxSeen + 50)).map(String.init))
        XCTAssertEqual(s.seen.count, AddonState.maxSeen); XCTAssertEqual(s.seen.last, "\(AddonState.maxSeen + 49)"); XCTAssertEqual(s.seen.first, "50")   // oldest fall off
        s.markSeen(["100"]); XCTAssertEqual(s.seen.count, AddonState.maxSeen)                                                                       // known ids aren't added twice
    }
    func testStateRoundTripsOnDisk() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("addons-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var s = AddonState(); s.muted = ["a@b.com"]; s.lastOK = true; s.lastTry = Date(timeIntervalSince1970: 1_700_000_000)
        s.pending = [AddonAlert(id: "1", addon: "gmail", sender: "S", address: "a@b.com", headline: "h", reason: "r", url: "u", score: 8, created: Date(timeIntervalSince1970: 1_700_000_000))]
        s.save(to: url)
        XCTAssertEqual(AddonState.load(from: url), s)
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
        XCTAssertEqual(AddonState.load(from: url.appendingPathExtension("missing")), AddonState())
    }
    func testSettingsLoadAndSaveKeepOtherKeys() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("s-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"default":"claude","addons":{"order":["gemma","claude","gemma","bogus"],"interval_hours":0.1,"importance":"  rent  ","gmail":{"client_id":" id ","client_secret":"sec"}}}"#.utf8).write(to: url)
        let s = AddonSettings.load(from: url)
        XCTAssertEqual(s.order, [.gemma, .claude]); XCTAssertEqual(s.intervalHours, 0.5); XCTAssertEqual(s.importance, "rent")
        XCTAssertEqual(s.gmail, GmailConfig(clientID: "id", clientSecret: "sec"))
        try AddonSettings.saveGmail(at: url, GmailConfig(clientID: "new", clientSecret: "n2"))
        XCTAssertEqual(AddonSettings.load(from: url).gmail?.clientID, "new")
        XCTAssertEqual(AddonSettings.load(from: url).order, [.gemma, .claude])                       // untouched
        XCTAssertEqual((try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])?["default"] as? String, "claude")
    }
    func testNoAddonsSectionMeansDefaults() {
        let s = AddonSettings.load(from: URL(fileURLWithPath: "/nonexistent/x.json"))
        XCTAssertNil(s.gmail); XCTAssertEqual(s.order, [.claude, .codex, .gemma]); XCTAssertEqual(s.intervalHours, 4)
    }

    // MARK: Gmail + OAuth

    func testGmailMessageParsing() {
        let j: [String: Any] = ["id": "m1", "threadId": "t1", "snippet": "Tom &amp; Jerry&#39;s", "internalDate": "1700000000000", "labelIds": ["INBOX", "UNREAD"],
                                "payload": ["headers": [["name": "From", "value": "A <a@b.com>"], ["name": "subject", "value": "Hello"], ["name": "List-Unsubscribe", "value": "<x>"]]]]
        let m = GmailAPI.parse(j)
        XCTAssertEqual(m?.from, "A <a@b.com>"); XCTAssertEqual(m?.subject, "Hello"); XCTAssertEqual(m?.snippet, "Tom & Jerry's")
        XCTAssertEqual(m?.bulk, true); XCTAssertEqual(m?.date, Date(timeIntervalSince1970: 1_700_000_000)); XCTAssertEqual(m?.labels, ["INBOX", "UNREAD"])
        XCTAssertNil(GmailAPI.parse(["threadId": "t"]))
    }
    func testPKCEMatchesRFC7636Vector() {
        XCTAssertEqual(GoogleOAuth.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let v = GoogleOAuth.verifier(); XCTAssertGreaterThanOrEqual(v.count, 43); XCTAssertNotEqual(v, GoogleOAuth.verifier())
    }
    func testAuthURLAsksForReadOnlyOfflineAccess() {
        let u = GoogleOAuth.authURL(clientID: "cid", redirect: "http://127.0.0.1:5000", challenge: "ch", state: "st").absoluteString
        XCTAssertTrue(u.contains("gmail.readonly")); XCTAssertTrue(u.contains("access_type=offline")); XCTAssertTrue(u.contains("code_challenge_method=S256"))
        XCTAssertFalse(u.contains("gmail.modify")); XCTAssertFalse(u.contains("gmail.send"))
    }
    func testCallbackParsing() {
        let ok = GoogleOAuth.parseCallback("GET /?code=4%2Fabc&state=xyz HTTP/1.1")
        XCTAssertEqual(ok?.code, "4/abc"); XCTAssertEqual(ok?.state, "xyz")
        XCTAssertEqual(GoogleOAuth.parseCallback("GET /?error=access_denied&state=s HTTP/1.1")?.error, "access_denied")
        XCTAssertNil(GoogleOAuth.parseCallback("GET /favicon.ico HTTP/1.1")); XCTAssertNil(GoogleOAuth.parseCallback("POST /?code=a HTTP/1.1")); XCTAssertNil(GoogleOAuth.parseCallback(""))
    }
    func testFormEncoding() {
        XCTAssertEqual(String(decoding: GoogleOAuth.form([("a", "b c"), ("c", "d&e=f/g")]), as: UTF8.self), "a=b%20c&c=d%26e%3Df%2Fg")
    }

    // MARK: locked-down model runs

    func testTriageRunsHaveNoToolsAndLeaveNoSession() {
        let c = AgentStream.lockedClaudeArgs(prompt: "p")
        XCTAssertEqual(c.firstIndex(of: "--tools").map { c[$0 + 1] }, "")
        XCTAssertTrue(c.contains("--no-session-persistence")); XCTAssertTrue(c.contains("--strict-mcp-config")); XCTAssertEqual(c.last, "p")
        XCTAssertFalse(c.contains("--allowedTools"))
        let x = AgentStream.lockedCodexArgs(prompt: "p")
        XCTAssertTrue(x.contains("--ephemeral")); XCTAssertEqual(x.firstIndex(of: "--sandbox").map { x[$0 + 1] }, "read-only")
    }
}

private actor Counter { var n = 0; func bump() { n += 1 } }
