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
    func testClaudeWorkModeAllowsEditsButNeverBash() {
        let a = AgentStream.claudeArgs(prompt: "x", session: nil, work: true)
        XCTAssertTrue(a.contains("acceptEdits"))
        let denied = a[(a.firstIndex(of: "--disallowedTools")! + 1)...].prefix { !$0.hasPrefix("--") }
        XCTAssertTrue(denied.contains("Bash"))
        XCTAssertFalse(denied.contains("Edit"))
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
