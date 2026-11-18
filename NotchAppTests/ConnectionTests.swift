import XCTest

final class ConnectionTests: XCTestCase {
    private let host = "vault.dextron04.in"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private let list = """
    Checking MCP server health…

    claude.ai Gmail: https://gmailmcp.googleapis.com/mcp/v1 - ✔ Connected
    claude.ai Dex Notch: https://vault.dextron04.in/mcp - ✔ Connected
    aws-mcp: uvx mcp-proxy-for-aws@latest https://aws-mcp.us-east-1.api.aws/mcp - ✘ Failed to connect — -32602: Invalid request parameters
    agentvault: /opt/homebrew/bin/python3 -m agentvault.mcp_server --vault /Users/x/Vault - ✔ Connected
    """

    func testClaudeListFindsTheDexServerByHost() {
        XCTAssertEqual(ConnectionLogic.parseClaudeList(list, host: host), .connected)
        XCTAssertEqual(ConnectionLogic.parseClaudeList(list, host: "other.example.com"), .missing)
        XCTAssertEqual(ConnectionLogic.parseClaudeList("", host: host), .missing)
    }
    func testClaudeListReadsLinesForServersAddedFromTheTerminal() {      // real output: the address is followed by "(HTTP)", then the status
        XCTAssertEqual(ConnectionLogic.parseClaudeList("dex-memory: https://vault.dextron04.in/mcp (HTTP) - ! Needs authentication", host: host), .needsSignIn)
        XCTAssertEqual(ConnectionLogic.parseClaudeList("dex-memory: https://vault.dextron04.in/mcp (HTTP) - ✔ Connected", host: host), .connected)
        XCTAssertEqual(ConnectionLogic.parseClaudeList("Checking MCP server health…\n\nother: https://a.example/mcp (HTTP) - ✔ Connected\ndex-memory: https://VAULT.dextron04.in/mcp (HTTP) - ✔ Connected\n", host: host), .connected)
    }
    func testClaudeListReadsSignInAndFailure() {
        XCTAssertEqual(ConnectionLogic.parseClaudeList("dex-memory: https://vault.dextron04.in/mcp - ! Needs authentication", host: host), .needsSignIn)
        XCTAssertEqual(ConnectionLogic.parseClaudeList("dex-memory: https://vault.dextron04.in/mcp - ✘ Failed to connect", host: host), .unknown)   // down is not "missing"
    }
    func testAnotherServersNameInTheLineIsNotAMatch() {
        XCTAssertEqual(ConnectionLogic.parseClaudeList("evil: https://evil.example.com/vault.dextron04.in - ✔ Connected", host: host), .missing)
    }

    private func codex(_ transport: String, enabled: Bool = true, auth: String = "o_auth") -> Data {
        Data("[{\"name\":\"dex-memory\",\"enabled\":\(enabled),\"transport\":\(transport),\"auth_status\":\"\(auth)\"}]".utf8)
    }
    func testCodexJSON() {
        let t = "{\"type\":\"streamable_http\",\"url\":\"https://vault.dextron04.in/mcp\"}"
        XCTAssertEqual(ConnectionLogic.parseCodex(codex(t), host: host), .connected)
        XCTAssertEqual(ConnectionLogic.parseCodex(codex(t, auth: "not_logged_in"), host: host), .needsSignIn)
        XCTAssertEqual(ConnectionLogic.parseCodex(codex(t, enabled: false), host: host), .missing)
        XCTAssertEqual(ConnectionLogic.parseCodex(codex("{\"type\":\"stdio\",\"command\":\"python3\"}"), host: host), .missing)
        XCTAssertEqual(ConnectionLogic.parseCodex(Data("not json".utf8), host: host), .unknown)
    }

    func testCodexJSONAsCodexReallyPrintsIt() {
        let json = Data(#"[{"name":"dex-memory","enabled":true,"disabled_reason":null,"transport":{"type":"streamable_http","url":"https://vault.dextron04.in/mcp","bearer_token_env_var":null,"http_headers":null,"env_http_headers":null,"http_headers_helper":null},"startup_timeout_sec":null,"tool_timeout_sec":null,"auth_status":"o_auth"}]"#.utf8)
        XCTAssertEqual(ConnectionLogic.parseCodex(json, host: host), .connected)                       // after a successful sign-in
        XCTAssertEqual(ConnectionLogic.parseCodex(Data(String(decoding: json, as: UTF8.self).replacingOccurrences(of: "o_auth", with: "not_logged_in").utf8), host: host), .needsSignIn)
    }
    func testServerAnswer() {
        let a = ConnectionLogic.parseAssistants(Data(#"{"email":"a@b.co","assistants":{"claude":true,"chatgpt":false}}"#.utf8))
        XCTAssertEqual(a?.claude, true); XCTAssertEqual(a?.chatgpt, false)
        XCTAssertNil(ConnectionLogic.parseAssistants(Data(#"{"email":"a@b.co"}"#.utf8)))      // an older server: no guess
        XCTAssertNil(a?.vault)                                                              // and no claim about the vault either
        XCTAssertEqual(ConnectionLogic.parseAssistants(Data(#"{"assistants":{},"vault_locked":true,"progress":{"uploaded":true,"used":false}}"#.utf8))?.vault, true)
        XCTAssertEqual(ConnectionLogic.parseAssistants(Data(#"{"assistants":{},"progress":{"uploaded":true,"used":false}}"#.utf8))?.used, false)
        XCTAssertEqual(ConnectionLogic.parseAssistants(Data(#"{"assistants":{"codex":true}}"#.utf8))?.codex, true)
        XCTAssertEqual(ConnectionLogic.lockURL(host: host)?.absoluteString, "https://vault.dextron04.in/account#vault-title")
        XCTAssertEqual(ConnectionLogic.web(nil), .unknown); XCTAssertEqual(ConnectionLogic.web(false), .missing)
    }

    private func report(_ s: [Surface: Conn]) -> ConnectionReport { ConnectionReport(states: s, checked: now) }
    func testClaudeCodeIsPartOfTheClaudeRowAndCodexPartOfChatGPT() {
        let r = report([.claude: .connected, .chatgpt: .connected, .codex: .missing])
        XCTAssertEqual(ConnectionLogic.rollUp(.claude, r, installed: [.claudeCode]).state, .connected)
        XCTAssertEqual(ConnectionLogic.rollUp(.chatgpt, r, installed: []).state, .connected)                    // no Codex here: nothing more to add
        let half = ConnectionLogic.rollUp(.chatgpt, r, installed: [.codex])
        XCTAssertEqual(half.state, .missing); XCTAssertEqual(half.detail, "Connected in ChatGPT. Codex still needs adding.")   // ChatGPT on the web does not pass connectors on to Codex
        XCTAssertEqual(ConnectionLogic.rollUp(.chatgpt, report([.chatgpt: .connected, .codex: .needsSignIn]), installed: [.codex]).state, .needsSignIn)
        XCTAssertEqual(ConnectionLogic.rollUp(.claude, report([.claude: .unknown]), installed: []).state, .unknown)
        XCTAssertEqual(ConnectionLogic.rollUp(.claude, nil, installed: []).detail, "Checking…")
    }
    func testAHalfKnownRowIsNotReportedAsAFailure() {
        func row(_ web: Conn, _ codex: Conn, codexHere: Bool = true) -> (state: Conn, detail: String) {
            ConnectionLogic.rollUp(.chatgpt, report([.chatgpt: web, .codex: codex]), installed: codexHere ? [.codex] : [])
        }
        XCTAssertEqual(row(.connected, .unknown).state, .connected)                      // ChatGPT is connected; Codex just couldn't be checked
        XCTAssertEqual(row(.unknown, .connected).state, .connected)                      // Codex is connected; ChatGPT on the web couldn't be checked
        XCTAssertEqual(row(.unknown, .unknown).state, .unknown)
        XCTAssertEqual(row(.unknown, .unknown, codexHere: false).state, .unknown)
        XCTAssertEqual(row(.unknown, .connected, codexHere: false).state, .unknown)      // no Codex here: that says nothing about ChatGPT
        XCTAssertEqual(row(.missing, .connected).detail, "Codex is connected. ChatGPT isn't yet.")
        XCTAssertEqual(row(.connected, .missing).state, .missing)
    }
    func testOnlyThingsThisMacHasAreWorthACard() {
        let r = report([.claude: .missing, .chatgpt: .missing, .claudeCode: .missing, .codex: .connected])
        XCTAssertEqual(ConnectionLogic.nudge(r, installed: [.claudeCode], nudged: [:], now: now, remind: true), .claude)
        XCTAssertNil(ConnectionLogic.nudge(r, installed: [], nudged: [:], now: now, remind: true))             // nothing installed: say nothing
        XCTAssertEqual(ConnectionLogic.nudge(r, installed: [.codex], nudged: [:], now: now, remind: true), .chatgpt)   // the web part of ChatGPT is still missing
        XCTAssertNil(ConnectionLogic.nudge(report([.chatgpt: .connected, .codex: .connected]), installed: [.codex], nudged: [:], now: now, remind: true))
    }
    func testNeverGuessesAndNeverNagsAndCanBeSwitchedOff() {
        let r = report([.claude: .unknown, .claudeCode: .unknown, .chatgpt: .missing])
        XCTAssertNil(ConnectionLogic.nudge(r, installed: [.claudeCode], nudged: [:], now: now, remind: true))     // couldn't check: not a reason to speak
        XCTAssertNil(ConnectionLogic.nudge(r, installed: [.chatgpt], nudged: ["chatgpt": now.addingTimeInterval(-86_400)], now: now, remind: true))
        XCTAssertEqual(ConnectionLogic.nudge(r, installed: [.chatgpt], nudged: ["chatgpt": now.addingTimeInterval(-4 * 86_400)], now: now, remind: true), .chatgpt)
        XCTAssertNil(ConnectionLogic.nudge(r, installed: [.chatgpt], nudged: [:], now: now, remind: false))
    }
    func testOneCardAtATimeInOrder() {
        let r = report([.claude: .missing, .chatgpt: .missing])
        XCTAssertEqual(ConnectionLogic.nudge(r, installed: [.claude, .chatgpt], nudged: [:], now: now, remind: true), .claude)
        XCTAssertEqual(ConnectionLogic.nudge(r, installed: [.claude, .chatgpt], nudged: ["claude": now], now: now, remind: true), .chatgpt)
    }
    func testTheNextStepFollowsTheOrderAndNeverGuesses() {
        func next(_ v: Bool?, _ r: Bool, _ u: Bool?, _ c: Bool?, _ x: Bool?) -> ConnectionLogic.Step? { ConnectionLogic.nextStep(vault: v, recording: r, uploaded: u, connected: c, used: x) }
        XCTAssertEqual(next(false, false, false, false, false), .vault)
        XCTAssertEqual(next(true, false, false, false, false), .record)
        XCTAssertEqual(next(true, true, nil, false, false), .connect)
        XCTAssertEqual(next(true, true, true, true, false), .firstChat)
        XCTAssertNil(next(true, true, true, true, true))
        XCTAssertNil(next(nil, true, nil, nil, nil))                       // the server didn't answer: nothing to say
        XCTAssertNil(next(true, false, true, true, true))                  // conversations arrived, so it works even if the helper isn't this Mac's
        XCTAssertEqual(ConnectionLogic.stepText(nil).title, "You're all set")
    }
    func testTheTrialPromptsAreTheOnesTheWebsiteShows() {
        XCTAssertEqual(ConnectionLogic.firstPrompt, "Remember this for me: I'm trying out Dex Memory, and my favorite color is amber.")
    }
    func testTheClaudeAddLinkPrefillsTheNameAndTheEncodedAddress() {
        XCTAssertEqual(ConnectionLogic.addToClaudeURL(host: host)?.absoluteString,
                       "https://claude.ai/customize/connectors?modal=add-custom-connector&connectorName=Dex%20Memory&connectorUrl=https%3A%2F%2Fvault%2Edextron04%2Ein%2Fmcp")
    }
    func testWordsAreHonest() {
        XCTAssertEqual(ConnectionLogic.detail(.codex, .missing, here: false), "Not installed on this Mac.")
        XCTAssertEqual(ConnectionLogic.detail(.codex, .needsSignIn, here: true), "Added, but not signed in yet.")
        XCTAssertTrue(ConnectionLogic.cardText(.chatgpt, .missing).headline.contains("ChatGPT"))
    }
}
