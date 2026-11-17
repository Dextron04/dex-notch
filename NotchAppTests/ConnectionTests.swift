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

    func testServerAnswer() {
        let a = ConnectionLogic.parseAssistants(Data(#"{"email":"a@b.co","assistants":{"claude":true,"chatgpt":false}}"#.utf8))
        XCTAssertEqual(a?.claude, true); XCTAssertEqual(a?.chatgpt, false)
        XCTAssertNil(ConnectionLogic.parseAssistants(Data(#"{"email":"a@b.co"}"#.utf8)))      // an older server: no guess
        XCTAssertEqual(ConnectionLogic.web(nil), .unknown); XCTAssertEqual(ConnectionLogic.web(false), .missing)
    }

    private func report(_ s: [Surface: Conn]) -> ConnectionReport { ConnectionReport(states: s, checked: now) }
    func testOnlyThingsThisMacHasAreWorthACard() {
        let r = report([.claude: .missing, .chatgpt: .missing, .claudeCode: .missing, .codex: .connected])
        XCTAssertEqual(ConnectionLogic.nudge(r, installed: [.claudeCode], nudged: [:], now: now, remind: true), .claudeCode)
        XCTAssertNil(ConnectionLogic.nudge(r, installed: [], nudged: [:], now: now, remind: true))          // nothing installed: say nothing
        XCTAssertNil(ConnectionLogic.nudge(r, installed: [.codex], nudged: [:], now: now, remind: true))    // it is connected
    }
    func testNeverGuessesAndNeverNagsAndCanBeSwitchedOff() {
        let r = report([.claudeCode: .unknown, .codex: .missing])
        XCTAssertNil(ConnectionLogic.nudge(r, installed: [.claudeCode], nudged: [:], now: now, remind: true))     // couldn't check: not a reason to speak
        let day = now.addingTimeInterval(-86_400)
        XCTAssertNil(ConnectionLogic.nudge(r, installed: [.codex], nudged: ["codex": day], now: now, remind: true))
        XCTAssertEqual(ConnectionLogic.nudge(r, installed: [.codex], nudged: ["codex": now.addingTimeInterval(-4 * 86_400)], now: now, remind: true), .codex)
        XCTAssertNil(ConnectionLogic.nudge(r, installed: [.codex], nudged: [:], now: now, remind: false))
    }
    func testOneCardAtATimeInOrder() {
        let r = report([.claude: .missing, .claudeCode: .missing])
        XCTAssertEqual(ConnectionLogic.nudge(r, installed: [.claude, .claudeCode], nudged: [:], now: now, remind: true), .claude)
        XCTAssertEqual(ConnectionLogic.nudge(r, installed: [.claude, .claudeCode], nudged: ["claude": now], now: now, remind: true), .claudeCode)
    }
    func testWordsAreHonest() {
        XCTAssertEqual(ConnectionLogic.detail(.codex, .missing, here: false), "Not installed on this Mac.")
        XCTAssertEqual(ConnectionLogic.detail(.claudeCode, .needsSignIn, here: true), "Added, but not signed in yet.")
        XCTAssertTrue(ConnectionLogic.cardText(.chatgpt, .missing).headline.contains("ChatGPT"))
    }
}
