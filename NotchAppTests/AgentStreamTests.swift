import XCTest

final class AgentStreamTests: XCTestCase {
    // MARK: routing

    func testNoPrefixIsGemma() {
        XCTAssertEqual(AgentStream.route("what is a monad"), Route(backend: .gemma, work: false, prompt: "what is a monad"))
    }
    func testClaudePrefix() {
        XCTAssertEqual(AgentStream.route("@claude  fix it "), Route(backend: .claude, work: false, prompt: "fix it"))
    }
    func testCodexPlusIsWork() {
        XCTAssertEqual(AgentStream.route("@codex+ refactor"), Route(backend: .codex, work: true, prompt: "refactor"))
    }
    func testPrefixIsCaseInsensitive() {
        XCTAssertEqual(AgentStream.route("@Claude hi").backend, .claude)
    }
    func testUnknownAtWordStaysGemmaWithFullText() {
        XCTAssertEqual(AgentStream.route("@bob look at this"), Route(backend: .gemma, work: false, prompt: "@bob look at this"))
    }
    func testPrefixGluedToWordIsNotAPrefix() {
        XCTAssertEqual(AgentStream.route("@claudeX hi").backend, .gemma)
    }
    func testPrefixAloneHasEmptyPrompt() {
        XCTAssertEqual(AgentStream.route("@claude"), Route(backend: .claude, work: false, prompt: ""))
    }

    // MARK: argument building

    func testClaudeAskModeIsReadOnlyAndPromptSurvivesVariadicFlags() {
        let a = AgentStream.claudeArgs(prompt: "-rf tricky", session: nil, work: false)
        XCTAssertEqual(a.last, "-rf tricky")
        XCTAssertEqual(a[a.count - 2], "--")                       // prompt can't be eaten by a variadic flag or parsed as an option
        XCTAssertTrue(a.contains("--disallowedTools"))
        let denied = a[(a.firstIndex(of: "--disallowedTools")! + 1)...].prefix { !$0.hasPrefix("--") }
        XCTAssertTrue(Set(["Bash", "Edit", "Write", "NotebookEdit"]).isSubset(of: denied))
        XCTAssertFalse(a.contains("acceptEdits"))
    }
    func testClaudeWorkModeAllowsEditsAndCommands() {
        let a = AgentStream.claudeArgs(prompt: "x", session: nil, work: true)
        XCTAssertTrue(a.contains("acceptEdits"))
        let allowed = a[(a.firstIndex(of: "--allowedTools")! + 1)...].prefix { !$0.hasPrefix("--") }
        XCTAssertTrue(Set(["Edit", "Write", "Bash", "Read"]).isSubset(of: allowed))
        XCTAssertFalse(a.contains("--disallowedTools") && a[(a.firstIndex(of: "--disallowedTools")! + 1)...].prefix { !$0.hasPrefix("--") }.contains("Bash"))
    }
    func testClaudeWorkModeRunsCommandsOnlyInsideTheOSSandbox() throws {
        let a = AgentStream.claudeArgs(prompt: "x", session: nil, work: true)
        let json = a[a.firstIndex(of: "--settings")! + 1]
        let sb = try XCTUnwrap((JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])?["sandbox"] as? [String: Any])
        XCTAssertEqual(sb["enabled"] as? Bool, true)
        XCTAssertEqual(sb["allowUnsandboxedCommands"] as? Bool, false)    // no escape hatch back to an unsandboxed shell
    }
    func testClaudeAskModeNeverGetsBashOrSandboxOverrides() {
        let a = AgentStream.claudeArgs(prompt: "x", session: nil, work: false)
        XCTAssertFalse(a.contains("--settings"))
        XCTAssertFalse(a[(a.firstIndex(of: "--allowedTools")! + 1)...].prefix { !$0.hasPrefix("--") }.contains("Bash"))
        XCTAssertTrue(a[(a.firstIndex(of: "--disallowedTools")! + 1)...].prefix { !$0.hasPrefix("--") }.contains("Bash"))
    }
    func testClaudeWorkModeTellsTheModelWhereItsLimitsAre() {
        let a = AgentStream.claudeArgs(prompt: "x", session: nil, work: true)
        XCTAssertTrue(a[a.firstIndex(of: "--append-system-prompt")! + 1].lowercased().contains("no network"))
    }
    func testClaudeResumeCarriesSession() {
        let a = AgentStream.claudeArgs(prompt: "x", session: "abc", work: false)
        XCTAssertEqual(a[a.firstIndex(of: "--resume")! + 1], "abc")
    }
    func testCodexSandboxModes() {
        XCTAssertEqual(AgentStream.codexArgs(prompt: "x", session: nil, work: false).drop { $0 != "--sandbox" }.dropFirst().first, "read-only")
        XCTAssertEqual(AgentStream.codexArgs(prompt: "x", session: nil, work: true).drop { $0 != "--sandbox" }.dropFirst().first, "workspace-write")
    }
    func testCodexResumeKeepsSandboxBeforeSubcommand() {
        let a = AgentStream.codexArgs(prompt: "x", session: "sid", work: false)
        XCTAssertLessThan(a.firstIndex(of: "--sandbox")!, a.firstIndex(of: "resume")!)
        XCTAssertEqual(Array(a.suffix(3)), ["resume", "sid", "x"])
    }
    func testCodexFreshEndsWithPrompt() {
        XCTAssertEqual(AgentStream.codexArgs(prompt: "x", session: nil, work: false).last, "x")
        XCTAssertFalse(AgentStream.codexArgs(prompt: "x", session: nil, work: false).contains("resume"))
    }

    // MARK: claude events

    func testClaudeTextDelta() {
        let l = #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hi"}}}"#
        XCTAssertEqual(AgentStream.claudeEvents(line: l), [.text("hi")])
    }
    func testClaudeToolStart() {
        let l = #"{"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","name":"Read","input":{}}}}"#
        XCTAssertEqual(AgentStream.claudeEvents(line: l), [.tool("Read")])
    }
    func testClaudeToolInputDeltaIsIgnored() {
        let l = #"{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"a\""}}}"#
        XCTAssertEqual(AgentStream.claudeEvents(line: l), [])
    }
    func testClaudeInitGivesSession() {
        XCTAssertEqual(AgentStream.claudeEvents(line: #"{"type":"system","subtype":"init","session_id":"s1"}"#), [.session("s1")])
    }
    func testClaudeResultCarriesFinalAndSession() {
        let l = #"{"type":"result","subtype":"success","is_error":false,"result":"done","session_id":"s1"}"#
        XCTAssertEqual(AgentStream.claudeEvents(line: l), [.session("s1"), .final("done")])
    }
    func testClaudeErrorResult() {
        let l = #"{"type":"result","subtype":"error_during_execution","is_error":true,"result":"boom","session_id":"s1"}"#
        XCTAssertEqual(AgentStream.claudeEvents(line: l), [.session("s1"), .error("boom")])
    }
    func testClaudeHookNoiseAndGarbageIgnored() {
        XCTAssertEqual(AgentStream.claudeEvents(line: #"{"type":"system","subtype":"hook_started"}"#), [])
        XCTAssertEqual(AgentStream.claudeEvents(line: "not json"), [])
        XCTAssertEqual(AgentStream.claudeEvents(line: ""), [])
    }

    // MARK: codex events

    func testCodexThreadStartedGivesSession() {
        XCTAssertEqual(AgentStream.codexEvents(line: #"{"type":"thread.started","thread_id":"t1"}"#), [.session("t1")])
    }
    func testCodexAgentMessage() {
        let l = #"{"type":"item.completed","item":{"id":"i","type":"agent_message","text":"hello"}}"#
        XCTAssertEqual(AgentStream.codexEvents(line: l), [.text("hello")])
    }
    func testCodexBudgetWarningItemIsIgnored() {
        let l = #"{"type":"item.completed","item":{"id":"i","type":"error","message":"Exceeded skills context budget"}}"#
        XCTAssertEqual(AgentStream.codexEvents(line: l), [])
    }
    func testCodexShellStartIsToolOnceNotTwice() {
        let s = #"{"type":"item.started","item":{"id":"i","type":"command_execution","command":"ls"}}"#
        let c = #"{"type":"item.completed","item":{"id":"i","type":"command_execution","command":"ls"}}"#
        XCTAssertEqual(AgentStream.codexEvents(line: s), [.tool("shell")])
        XCTAssertEqual(AgentStream.codexEvents(line: c), [])
    }
    func testCodexTurnFailed() {
        XCTAssertEqual(AgentStream.codexEvents(line: #"{"type":"turn.failed","error":{"message":"nope"}}"#), [.error("nope")])
    }
}

final class MemoryRecallTests: XCTestCase {
    private func json(_ sources: [[String: String]]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["live": 5, "sources": sources])
    }
    private func src(_ source: String, _ title: String = "T", _ snippet: String = "s") -> [String: String] {
        ["id": "1", "title": title, "source": source, "heading": "h", "snippet": snippet]
    }

    func testOnlyVaultSourcesAreKept() {
        let r = AgentStream.parseSnippets(json([src("vault:Sessions/codex/a.md", "A"), src("docs/readme.md", "Other")]))
        XCTAssertEqual(r.map(\.title), ["A"])
    }
    func testAtMostTwoSnippetsPerNoteAndFiveTotal() {
        let many = (0..<4).map { src("vault:Sessions/x/a.md", "A", "s\($0)") } + (0..<6).map { src("vault:Sessions/x/b\($0).md", "B\($0)") }
        let r = AgentStream.parseSnippets(json(many))
        XCTAssertEqual(r.filter { $0.source == "Sessions/x/a.md" }.count, 2)
        XCTAssertEqual(r.count, 5)
    }
    func testSourcePrefixIsStrippedToVaultRelativePath() {
        XCTAssertEqual(AgentStream.parseSnippets(json([src("vault:Sessions/gemini/z.md")])).first?.source, "Sessions/gemini/z.md")
    }
    func testMalformedOrEmptyResponseGivesNoSnippets() {
        XCTAssertEqual(AgentStream.parseSnippets(Data("nope".utf8)), [])
        XCTAssertEqual(AgentStream.parseSnippets(json([])), [])
        XCTAssertEqual(AgentStream.parseSnippets(Data(#"{"error":"x"}"#.utf8)), [])
    }
    func testMemoryPromptEmptyWhenNothingFound() {
        XCTAssertEqual(AgentStream.memoryPrompt([]), "")
    }
    func testMemoryPromptCarriesTitlesSnippetsAndHonestyRule() {
        let p = AgentStream.memoryPrompt([Snippet(title: "Notch picker", source: "Sessions/claude-code/2026-11/a.md", snippet: "we chose claude -p")])
        XCTAssertTrue(p.contains("Notch picker")); XCTAssertTrue(p.contains("we chose claude -p"))
        XCTAssertTrue(p.contains("2026-11"))                         // date hint from the path
        XCTAssertTrue(p.lowercased().contains("do not invent"))      // must not fabricate beyond the notes
    }
    func testMemoryPromptIsCappedByLimit() {
        let big = (0..<5).map { Snippet(title: "N\($0)", source: "Sessions/x/\($0).md", snippet: String(repeating: "z", count: 2000)) }
        XCTAssertLessThanOrEqual(AgentStream.memoryPrompt(big, limit: 3000).count, 3300)  // limit + fixed header/footer
    }
}

final class ModelDialTests: XCTestCase {
    func testCycleForwardWraps() {
        XCTAssertEqual(AgentStream.cycle(.gemma, by: 1), .claude)
        XCTAssertEqual(AgentStream.cycle(.claude, by: 1), .codex)
        XCTAssertEqual(AgentStream.cycle(.codex, by: 1), .gemma)
    }
    func testCycleBackwardWraps() {
        XCTAssertEqual(AgentStream.cycle(.gemma, by: -1), .codex)
        XCTAssertEqual(AgentStream.cycle(.codex, by: -1), .claude)
    }
    func testTypedPrefixConvertsOnceTheSpaceArrives() {
        let c = AgentStream.consumePrefix("@claude ")
        XCTAssertEqual(c?.backend, .claude); XCTAssertEqual(c?.work, false); XCTAssertEqual(c?.rest, "")
    }
    func testPlusMeansEditsAndRestIsKept() {
        let c = AgentStream.consumePrefix("@codex+ refactor it")
        XCTAssertEqual(c?.backend, .codex); XCTAssertEqual(c?.work, true); XCTAssertEqual(c?.rest, "refactor it")
    }
    func testStillTypingTheNameDoesNothing() {
        XCTAssertNil(AgentStream.consumePrefix("@claud")); XCTAssertNil(AgentStream.consumePrefix("@claude"))
    }
    func testPrefixOnlyCountsAtTheStart() {
        XCTAssertNil(AgentStream.consumePrefix("hello @claude "))
    }
    func testUnknownNamesAndGluedWordsAreLeftAlone() {
        XCTAssertNil(AgentStream.consumePrefix("@bob hi")); XCTAssertNil(AgentStream.consumePrefix("@claudeX hi"))
    }
    func testCaseInsensitiveAndGemmaNeverGetsEdits() {
        XCTAssertEqual(AgentStream.consumePrefix("@Gemma+ x")?.backend, .gemma)
        XCTAssertEqual(AgentStream.consumePrefix("@Gemma+ x")?.work, false)
        XCTAssertEqual(AgentStream.consumePrefix("@CLAUDE hi")?.backend, .claude)
    }
}

final class ConversationLifetimeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testNeverClosedIsNotStale() { XCTAssertFalse(AgentStream.isStale(closedAt: nil, now: now)) }
    func testReopenedWithinTheWindowKeepsTheConversation() {
        XCTAssertFalse(AgentStream.isStale(closedAt: now.addingTimeInterval(-60), now: now))
        XCTAssertFalse(AgentStream.isStale(closedAt: now.addingTimeInterval(-1799), now: now))
    }
    func testLongAbsenceStartsFresh() {
        XCTAssertTrue(AgentStream.isStale(closedAt: now.addingTimeInterval(-1801), now: now))
    }
    func testWindowIsConfigurable() {
        XCTAssertTrue(AgentStream.isStale(closedAt: now.addingTimeInterval(-61), now: now, after: 60))
    }
    func testClockGoingBackwardsDoesNotWipe() {
        XCTAssertFalse(AgentStream.isStale(closedAt: now.addingTimeInterval(500), now: now))
    }
}

final class WorkFolderTests: XCTestCase {
    private let list = ["/Users/me/Desktop", "/Users/me/Projects"]
    func testFolderCycleStartsAtSandboxAndWraps() {
        XCTAssertEqual(AgentStream.nextFolder(nil, in: list), "/Users/me/Desktop")
        XCTAssertEqual(AgentStream.nextFolder("/Users/me/Desktop", in: list), "/Users/me/Projects")
        XCTAssertNil(AgentStream.nextFolder("/Users/me/Projects", in: list))               // back to the scratch sandbox
        XCTAssertEqual(AgentStream.nextFolder("/Users/me/Gone", in: list), "/Users/me/Desktop") // a folder no longer in the list recovers
    }
    func testEmptyListStaysOnTheSandbox() { XCTAssertNil(AgentStream.nextFolder(nil, in: [])) }
    func testBuiltInListIsTheFourStandardFolders() {
        let home = URL(fileURLWithPath: "/Users/me")
        XCTAssertEqual(AgentStream.folderChoices(configured: nil, defaultFolder: nil, home: home),
                       ["/Users/me/Desktop", "/Users/me/Downloads", "/Users/me/Documents", "/Users/me/Projects"])
    }
    func testConfiguredListReplacesTheBuiltInOne() {
        XCTAssertEqual(AgentStream.folderChoices(configured: ["/Users/me/code"], defaultFolder: nil, home: URL(fileURLWithPath: "/Users/me")), ["/Users/me/code"])
    }
    func testTheDefaultWorkspaceIsAlwaysSelectableEvenIfNotListed() {
        XCTAssertEqual(AgentStream.folderChoices(configured: ["/Users/me/code"], defaultFolder: "/Users/me/work", home: URL(fileURLWithPath: "/Users/me")),
                       ["/Users/me/code", "/Users/me/work"])
    }
    func testFolderLabelIsTheLastPathComponent() {
        XCTAssertEqual(AgentStream.folderLabel("/Users/me/Projects/app"), "app"); XCTAssertEqual(AgentStream.folderLabel(nil), "sandbox")
    }
    private func settings(_ a: [String]) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(a[a.firstIndex(of: "--settings")! + 1].utf8)) as? [String: Any])
    }
    func testClaudeWorkWithFolderGrantsWriteToExactlyThatFolderKeepingTheSandbox() throws {
        let sb = try XCTUnwrap(try settings(AgentStream.claudeArgs(prompt: "x", session: nil, work: true, folder: "/Users/me/Desktop"))["sandbox"] as? [String: Any])
        XCTAssertEqual(sb["enabled"] as? Bool, true); XCTAssertEqual(sb["allowUnsandboxedCommands"] as? Bool, false)
        XCTAssertEqual((sb["filesystem"] as? [String: Any])?["allowWrite"] as? [String], ["/Users/me/Desktop"])
    }
    func testClaudeWorkWithoutFolderHasNoExtraWriteAccess() throws {
        let sb = try XCTUnwrap(try settings(AgentStream.claudeArgs(prompt: "x", session: nil, work: true))["sandbox"] as? [String: Any])
        XCTAssertNil(sb["filesystem"])
    }
    func testFolderPathWithQuotesStillProducesValidJSON() throws {
        let sb = try XCTUnwrap(try settings(AgentStream.claudeArgs(prompt: "x", session: nil, work: true, folder: "/Users/me/My \"odd\" dir"))["sandbox"] as? [String: Any])
        XCTAssertEqual((sb["filesystem"] as? [String: Any])?["allowWrite"] as? [String], ["/Users/me/My \"odd\" dir"])
    }
    func testAskModeIgnoresTheFolder() {
        let c = AgentStream.claudeArgs(prompt: "x", session: nil, work: false, folder: "/Users/me/Desktop")
        XCTAssertFalse(c.contains("--settings")); XCTAssertFalse(c.joined().contains("/Users/me/Desktop"))
        XCTAssertFalse(AgentStream.codexArgs(prompt: "x", session: nil, work: false, folder: "/Users/me/Desktop").contains("--add-dir"))
    }
    func testCodexWorkWithFolderAddsItBeforeResume() {
        let a = AgentStream.codexArgs(prompt: "x", session: "sid", work: true, folder: "/Users/me/Desktop")
        XCTAssertEqual(a[a.firstIndex(of: "--add-dir")! + 1], "/Users/me/Desktop")
        XCTAssertLessThan(a.firstIndex(of: "--add-dir")!, a.firstIndex(of: "resume")!)
        XCTAssertEqual(a.last, "x")
    }
}

final class FirstRunTests: XCTestCase {
    func testDefaultPrefersTheSettingWhenThatModelExists() {
        XCTAssertEqual(AgentStream.defaultBackend(choices: [.gemma, .claude, .codex], preferred: .codex), .codex)
    }
    func testDefaultFallsBackToClaudeThenCodexThenGemma() {
        XCTAssertEqual(AgentStream.defaultBackend(choices: [.gemma, .claude, .codex], preferred: nil), .claude)
        XCTAssertEqual(AgentStream.defaultBackend(choices: [.gemma, .codex], preferred: nil), .codex)
        XCTAssertEqual(AgentStream.defaultBackend(choices: [.gemma], preferred: nil), .gemma)
    }
    func testPreferredButMissingModelIsIgnored() {
        XCTAssertEqual(AgentStream.defaultBackend(choices: [.codex], preferred: .claude), .codex)
    }
    func testNothingAvailableMeansNoDefault() { XCTAssertNil(AgentStream.defaultBackend(choices: [], preferred: .claude)) }

    func testCycleOnlyVisitsModelsThatExist() {
        XCTAssertEqual(AgentStream.cycle(.claude, by: 1, among: [.claude, .codex]), .codex)
        XCTAssertEqual(AgentStream.cycle(.codex, by: 1, among: [.claude, .codex]), .claude)     // wraps, skipping the absent gemma
        XCTAssertEqual(AgentStream.cycle(.claude, by: -1, among: [.claude, .codex]), .codex)
        XCTAssertEqual(AgentStream.cycle(.claude, by: 1, among: [.claude]), .claude)            // one choice: nowhere to go
    }
    func testCycleFromAModelNoLongerAvailableLandsOnTheFirst() {
        XCTAssertEqual(AgentStream.cycle(.gemma, by: 1, among: [.claude, .codex]), .claude)
    }

    func testLocateFindsTheFirstExecutableOnPATH() {
        let have: Set<String> = ["/opt/homebrew/bin/claude", "/usr/local/bin/claude", "/usr/local/bin/codex"]
        XCTAssertEqual(AgentStream.locate("claude", inPATH: "/usr/bin:/opt/homebrew/bin:/usr/local/bin") { have.contains($0) }, "/opt/homebrew/bin/claude")
        XCTAssertEqual(AgentStream.locate("codex", inPATH: "/usr/bin:/opt/homebrew/bin:/usr/local/bin") { have.contains($0) }, "/usr/local/bin/codex")
        XCTAssertNil(AgentStream.locate("gemini", inPATH: "/usr/bin") { have.contains($0) })
    }
    func testLocateIgnoresEmptyPATHEntries() {
        XCTAssertNil(AgentStream.locate("claude", inPATH: "::/usr/bin:") { $0 == "/claude" })   // an empty entry must not mean "/claude"
    }
}

final class ModelIdentityTests: XCTestCase {
    func testDisplayNamesAreForPeopleAndAccessibility() {
        XCTAssertEqual(Backend.claude.displayName, "Claude"); XCTAssertEqual(Backend.codex.displayName, "Codex")
        XCTAssertEqual(Backend.gemma.displayName, "Local model")     // the custom Ollama connector is not necessarily Gemma
    }
    func testCLIOverrideForDemosAndTests() {
        XCTAssertEqual(AgentStream.parseCLIOverride("none"), [])
        XCTAssertEqual(AgentStream.parseCLIOverride("claude"), [.claude])
        XCTAssertEqual(AgentStream.parseCLIOverride(" Claude , codex "), [.claude, .codex])
        XCTAssertEqual(AgentStream.parseCLIOverride("claude,gemma,nonsense"), [.claude])      // only real CLIs count
        XCTAssertNil(AgentStream.parseCLIOverride(nil)); XCTAssertNil(AgentStream.parseCLIOverride(""))
    }
}

final class BackendAfterDetectionTests: XCTestCase {
    private let all: [Backend] = [.gemma, .claude, .codex]
    func testFirstDetectionWithNoConversationAppliesTheDefault() {
        XCTAssertEqual(AgentStream.backendAfterDetection(current: .claude, firstDetection: true, hasConversation: false, choices: all, preferred: .codex), .codex)
    }
    func testLaterChecksNeverOverrideAChoiceTheUserMade() {     // the bug: reopening the notch reset Codex back to Claude
        XCTAssertEqual(AgentStream.backendAfterDetection(current: .codex, firstDetection: false, hasConversation: false, choices: all, preferred: .claude), .codex)
    }
    func testARestoredConversationKeepsItsModelOnFirstDetection() {
        XCTAssertEqual(AgentStream.backendAfterDetection(current: .codex, firstDetection: true, hasConversation: true, choices: all, preferred: .claude), .codex)
    }
    func testAModelThatDisappearedIsReplacedEvenMidConversation() {
        XCTAssertEqual(AgentStream.backendAfterDetection(current: .codex, firstDetection: false, hasConversation: true, choices: [.claude], preferred: nil), .claude)
    }
    func testNothingAvailableLeavesTheSelectionAlone() {
        XCTAssertEqual(AgentStream.backendAfterDetection(current: .claude, firstDetection: true, hasConversation: false, choices: [], preferred: .codex), .claude)
    }
}

final class GemmaRequestTests: XCTestCase {
    private let msgs: [[String: String]] = [["role": "user", "content": "hi"]]

    func testChatBodyKeepsTheModelLoadedSoTheNextQuestionIsNotAColdStart() {
        let b = AgentStream.gemmaChatBody(model: "m", messages: msgs)
        XCTAssertEqual(b["keep_alive"] as? String, "30m")
    }
    func testChatBodyCapsTheLengthSoOneAnswerCannotHogTheServer() {
        let o = AgentStream.gemmaChatBody(model: "m", messages: msgs)["options"] as? [String: Any]
        XCTAssertEqual(o?["num_predict"] as? Int, 1024)
    }
    func testChatBodyKeepsWhatItAlwaysHad() {
        let b = AgentStream.gemmaChatBody(model: "gemma3:12b", messages: msgs)
        XCTAssertEqual(b["model"] as? String, "gemma3:12b"); XCTAssertEqual(b["stream"] as? Bool, true); XCTAssertEqual(b["think"] as? Bool, false)
        XCTAssertEqual((b["messages"] as? [[String: String]])?.first?["content"], "hi")
    }
    func testWarmUpBodyJustLoadsTheModel() {
        let b = AgentStream.gemmaWarmBody(model: "m")
        XCTAssertEqual(b["model"] as? String, "m"); XCTAssertEqual(b["keep_alive"] as? String, "30m")
        XCTAssertNil(b["prompt"]); XCTAssertNil(b["messages"])          // no prompt: Ollama only loads the model
    }
    func testWarmUpIsThrottledSoOpeningTheNotchRepeatedlyDoesNotHammerTheServer() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(AgentStream.shouldWarm(last: nil, now: t0))
        XCTAssertFalse(AgentStream.shouldWarm(last: t0, now: t0.addingTimeInterval(60)))
        XCTAssertFalse(AgentStream.shouldWarm(last: t0, now: t0.addingTimeInterval(20 * 60)))   // still inside the 30-minute keep-alive
        XCTAssertTrue(AgentStream.shouldWarm(last: t0, now: t0.addingTimeInterval(26 * 60)))    // refresh just before it would expire
    }
}
