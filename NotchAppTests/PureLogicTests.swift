import XCTest

/// Rules that live in pure code and had no test of their own: the reminder limits, the account gate's edges, the start-up step words.
final class PureLogicTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: reminders. AddonCenter.retire uses these constants to decide when a reminder stops coming back.

    func testReminderLimitsAreWhatTheDocsPromise() {
        XCTAssertEqual(Reminders.staleAfter, 86_400)      // a day overdue: marked done without a card
        XCTAssertEqual(Reminders.snooze, 600)             // an ignored reminder returns in ten minutes
        XCTAssertEqual(Reminders.maxShows, 3)             // and gives up after three showings
    }
    func testWhoSetTheReminderIsNamedHonestly() {
        func name(_ s: String) -> String { Reminder(id: "x", text: "t", source: s, due: now).sourceName }
        XCTAssertEqual(name("chatgpt"), "ChatGPT"); XCTAssertEqual(name("claude-web"), "Claude")
        XCTAssertEqual(name("other-ai"), "an assistant"); XCTAssertEqual(name(""), "an assistant")
    }
    func testDueRemindersComeOldestFirstAndSnoozeIsPerReminder() {
        let a = Reminder(id: "a", text: "a", source: "", due: now.addingTimeInterval(-300))
        let b = Reminder(id: "b", text: "b", source: "", due: now.addingTimeInterval(-100))
        let c = Reminder(id: "c", text: "c", source: "", due: now.addingTimeInterval(-900))
        XCTAssertEqual(Reminders.due([a, b, c], done: [], snoozed: [:], now: now).map(\.id), ["a", "b", "c"])    // the order given: load() sorts by due time
        XCTAssertEqual(Reminders.due([a, b, c], done: ["b"], snoozed: ["c": now.addingTimeInterval(1)], now: now).map(\.id), ["a"])
        XCTAssertEqual(Reminders.due([a], done: [], snoozed: ["a": now], now: now).map(\.id), ["a"])           // a snooze that ends exactly now is over
    }
    func testLoadSortsByDueAndSkipsSyncConflictsAndIncompleteFiles() throws {
        let vault = FileManager.default.temporaryDirectory.appendingPathComponent("rem-\(UUID().uuidString)")
        let dir = vault.appendingPathComponent("Reminders"); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vault) }
        func put(_ file: String, id: String?, due: String?, text: String?) throws {
            var h = "---\n"
            if let id { h += "id: \"\(id)\"\n" }; if let due { h += "due: \"\(due)\"\n" }; if let text { h += "text: \"\(text)\"\n" }
            try (h + "---\n").write(to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        try put("late.md", id: "late", due: "2026-11-17T09:00:00Z", text: "second")
        try put("early.md", id: "early", due: "2026-11-16T09:00:00Z", text: "first")
        try put("early.sync-conflict-20261117-abc.md", id: "dup", due: "2026-11-16T09:00:00Z", text: "copy")
        try put("notext.md", id: "n", due: "2026-11-16T09:00:00Z", text: "")
        try put("nodue.md", id: "d", due: nil, text: "x")
        try put("noid.md", id: nil, due: "2026-11-16T09:00:00Z", text: "x")
        try "id: ignored".write(to: dir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        XCTAssertEqual(Reminders.load(vault: vault).map(\.id), ["early", "late"])
        XCTAssertEqual(Reminders.load(vault: vault.appendingPathComponent("nowhere")), [])
    }

    // MARK: the account gate

    func testTheGraceEndsExactlyAtSevenDaysAndAMinuteOfClockSlackIsAllowed() {
        func v(_ last: Date) -> GateVerdict { Gate.decide(hasToken: true, answer: .unreachable, lastConfirmed: last, now: now) }
        XCTAssertEqual(Gate.grace, 7 * 86_400)
        XCTAssertEqual(v(now.addingTimeInterval(-Gate.grace + 1)), .open)
        XCTAssertEqual(v(now.addingTimeInterval(-Gate.grace)), .locked)
        XCTAssertEqual(v(now.addingTimeInterval(30)), .open)          // a few seconds of clock drift
        XCTAssertEqual(v(now.addingTimeInterval(61)), .locked)        // a confirmation from the future is not trusted
    }
    func testAnAnswerFromTheServerBeatsAnyEarlierConfirmation() {
        XCTAssertEqual(Gate.decide(hasToken: true, answer: .confirmed(email: "a@b.co"), lastConfirmed: nil, now: now), .open)
        XCTAssertEqual(Gate.decide(hasToken: true, answer: .rejected, lastConfirmed: now, now: now), .needsAccount)
    }

    // MARK: getting started

    func testEveryStepHasWordsAndAButtonExceptTheLast() {
        for s in ConnectionLogic.Step.allCases {
            let t = ConnectionLogic.stepText(s)
            XCTAssertFalse(t.title.isEmpty); XCTAssertFalse(t.detail.isEmpty); XCTAssertFalse(t.button.isEmpty, "\(s)")
        }
        XCTAssertEqual(ConnectionLogic.stepText(nil).button, "")
    }
    func testTheVaultStepOffersAPasskeyOrAPassphrase() {
        let t = ConnectionLogic.stepText(.vault)
        XCTAssertEqual(t.title, "Lock your vault")
        XCTAssertTrue(t.detail.hasPrefix("Create a passkey, or use a passphrase."))
        XCTAssertFalse(t.detail.contains("Touch ID"))
    }
    func testConnectionAddressesAreBuiltFromTheHostOnly() {
        XCTAssertEqual(ConnectionLogic.mcpURL(host: "h.example"), "https://h.example/mcp")
        XCTAssertEqual(ConnectionLogic.guideURL(host: "h.example", .claudeCode)?.absoluteString, "https://h.example/connect#claude-code")
        XCTAssertEqual(ConnectionLogic.lockURL(host: "h.example")?.absoluteString, "https://h.example/account#vault-title")
        XCTAssertEqual(Surface.allCases.filter(\.isCLI), [.claudeCode, .codex])
    }
}
