import XCTest

final class ScreenToolTests: XCTestCase {
    let l = ScreenTool.Launch(exe: "/Apps/Dex Notch.app/Contents/MacOS/Dex Notch", socket: "/s/screen.sock", token: "tok")
    func obj(_ s: String?) -> [String: Any] { (try? JSONSerialization.jsonObject(with: Data((s ?? "{}").utf8))) as? [String: Any] ?? [:] }
    let ok: (String?) -> Result<ScreenTool.Look, ScreenTool.LookError> = { _ in .success(.init(png: Data([1, 2, 3]), width: 1512, height: 982)) }

    func testInitializeAndList() {
        let i = obj(ScreenTool.reply(to: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}"#, look: ok))
        XCTAssertEqual((i["result"] as? [String: Any])?["protocolVersion"] as? String, "2025-03-26")
        let t = obj(ScreenTool.reply(to: #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#, look: ok))
        XCTAssertEqual((((t["result"] as? [String: Any])?["tools"]) as? [[String: Any]])?.first?["name"] as? String, "look_at_screen")
    }
    func testCallReturnsImageBlockAndSizeText() {
        let r = obj(ScreenTool.reply(to: #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"look_at_screen","arguments":{"reason":"x"}}}"#, look: ok))
        let c = (r["result"] as? [String: Any])?["content"] as? [[String: Any]]
        XCTAssertEqual(c?[0]["type"] as? String, "image"); XCTAssertEqual(c?[0]["mimeType"] as? String, "image/png")
        XCTAssertEqual(c?[0]["data"] as? String, Data([1, 2, 3]).base64EncodedString())
        XCTAssertTrue((c?[1]["text"] as? String)?.contains("1512×982 px") == true)
    }
    func testRefusedCallIsAnErrorResultAndReasonIsPassedThrough() {
        var seen: String?
        let r = obj(ScreenTool.reply(to: #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"look_at_screen","arguments":{"reason":"why"}}}"#, look: { seen = $0; return .failure(.init(message: "closed")) }))
        XCTAssertEqual(seen, "why")
        XCTAssertEqual((r["result"] as? [String: Any])?["isError"] as? Bool, true)
    }
    func testNotificationsAndUnknownMethods() {
        XCTAssertNil(ScreenTool.reply(to: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, look: ok))
        XCTAssertNil(ScreenTool.reply(to: "not json", look: ok))
        XCTAssertNotNil(obj(ScreenTool.reply(to: #"{"jsonrpc":"2.0","id":5,"method":"nope"}"#, look: ok))["error"])
        XCTAssertNotNil(obj(ScreenTool.reply(to: #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"other"}}"#, look: ok))["error"])
    }
    func testLimitIsThreePerTurn() {
        var lim = ScreenTool.Limiter()
        XCTAssertEqual((0..<5).map { _ in lim.take() }, [true, true, true, false, false])
    }
    func testSettingAndBackendGateTheTool() {
        XCTAssertTrue(ScreenTool.offered(.claude, setting: true)); XCTAssertTrue(ScreenTool.offered(.codex, setting: true))
        XCTAssertFalse(ScreenTool.offered(.claude, setting: false)); XCTAssertFalse(ScreenTool.offered(.gemma, setting: true))
    }
    func testSettingDefaultsOnAndRoundTrips() throws {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("s-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: u) }
        XCTAssertTrue(Settings.modelsMayLook(at: u))
        try Settings.setModelsMayLook(at: u, false); XCTAssertFalse(Settings.modelsMayLook(at: u))
        try Settings.setModelsMayLook(at: u, true); XCTAssertTrue(Settings.modelsMayLook(at: u))
    }
    func testClaudeGetsAConfigAndAllowRuleOnlyWhenOffered() {
        let a = AgentStream.claudeArgs(prompt: "q", session: nil, work: false, look: l)
        let cfg = a[(a.firstIndex(of: "--mcp-config")! + 1)]
        let s = (obj(cfg)["mcpServers"] as? [String: Any])?["screen"] as? [String: Any]
        XCTAssertEqual(s?["command"] as? String, l.exe); XCTAssertEqual(s?["args"] as? [String], ["--screen-mcp"])
        XCTAssertEqual((s?["env"] as? [String: String])?["DEX_SCREEN_TOKEN"], "tok")
        XCTAssertTrue(a.contains("mcp__screen"))
        let none = AgentStream.claudeArgs(prompt: "q", session: nil, work: false)
        XCTAssertFalse(none.contains("mcp__screen")); XCTAssertFalse(none.contains("--mcp-config") && none.joined().contains("screen"))
    }
    func testCodexGetsConfigOverridesBeforeTheSubcommandFlags() {
        let a = AgentStream.codexArgs(prompt: "q", session: "sid", work: false, look: l)
        XCTAssertEqual(a.first, "exec")
        XCTAssertTrue(a.contains(#"mcp_servers.screen.command="/Apps/Dex Notch.app/Contents/MacOS/Dex Notch""#))
        XCTAssertTrue(a.contains(#"mcp_servers.screen.args=["--screen-mcp"]"#))
        XCTAssertTrue(a.contains(#"mcp_servers.screen.env={DEX_SCREEN_SOCK="/s/screen.sock", DEX_SCREEN_TOKEN="tok"}"#))
        XCTAssertLessThan(a.firstIndex(of: "-c")!, a.firstIndex(of: "resume")!)
        XCTAssertFalse(AgentStream.codexArgs(prompt: "q", session: nil, work: false).contains("-c"))
    }
    func testLockedMailRunsNeverGetTheTool() {
        XCTAssertFalse(AgentStream.lockedClaudeArgs(prompt: "q").joined().contains("screen"))
        XCTAssertFalse(AgentStream.lockedCodexArgs(prompt: "q").contains("-c"))
    }
}
