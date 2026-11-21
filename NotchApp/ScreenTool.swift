import Foundation

/// The `look_at_screen` tool the models can call themselves: the MCP wire format, the per-turn limit, and the config handed to each CLI.
/// Pure. The server process is the app binary run with `--screen-mcp` (see ScreenBridge.swift); it asks the running app to capture.
enum ScreenTool {
    static let server = "screen", name = "look_at_screen", flag = "--screen-mcp", maxPerTurn = 3
    static let sockEnv = "DEX_SCREEN_SOCK", tokenEnv = "DEX_SCREEN_TOKEN"

    /// How to start the server and where to reach the app. `token` is per question: requests without the live one are refused.
    struct Launch: Equatable { var exe: String, socket: String, token: String }
    struct Look { var png: Data; var width: Int; var height: Int }
    struct Limiter {
        var used = 0
        mutating func take() -> Bool { guard used < ScreenTool.maxPerTurn else { return false }; used += 1; return true }
    }

    /// Told to the model next to the question, so it knows the tool exists and when not to use it.
    static let hint = "You have a look_at_screen tool. Call it only when the answer depends on what is on the user's screen right now, never just to check. Coordinates are in the screenshot it returns. " + ScreenMarks.markSyntax

    /// Only the CLIs get it (the local model can't see), and only while the setting is on.
    static func offered(_ b: Backend, setting: Bool) -> Bool { b != .gemma && setting }

    // MARK: config for each CLI

    static func claudeConfig(_ l: Launch) -> String {
        let srv: [String: Any] = ["command": l.exe, "args": [flag], "env": [sockEnv: l.socket, tokenEnv: l.token]]
        let d = try? JSONSerialization.data(withJSONObject: ["mcpServers": [server: srv]], options: [.withoutEscapingSlashes, .sortedKeys])
        return d.map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    /// Codex takes MCP servers as `-c` TOML overrides, so nothing is written to the user's config.toml.
    static func codexArgs(_ l: Launch) -> [String] {
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        return ["-c", "mcp_servers.\(server).command=\(q(l.exe))", "-c", "mcp_servers.\(server).args=[\(q(flag))]",
                "-c", "mcp_servers.\(server).env={\(sockEnv)=\(q(l.socket)), \(tokenEnv)=\(q(l.token))}"]
    }

    // MARK: MCP (JSON-RPC over stdio, one message per line)

    /// The reply to one request line, or nil when none is due (notifications, or garbage).
    static func reply(to line: String, look: (String?) -> Result<Look, LookError>) -> String? {
        guard let d = line.data(using: .utf8), let req = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let method = req["method"] as? String, let id = req["id"] else { return nil }
        let params = req["params"] as? [String: Any]
        var out: [String: Any] = ["jsonrpc": "2.0", "id": id]
        switch method {
        case "initialize":
            out["result"] = ["protocolVersion": (params?["protocolVersion"] as? String) ?? "2024-11-05", "capabilities": ["tools": [String: Any]()],
                             "serverInfo": ["name": "dex-notch-screen", "version": "1"]] as [String: Any]
        case "ping": out["result"] = [String: Any]()
        case "tools/list": out["result"] = ["tools": [tool]]
        case "tools/call":
            guard (params?["name"] as? String) == name else { out["error"] = ["code": -32602, "message": "Unknown tool"]; break }
            switch look((params?["arguments"] as? [String: Any])?["reason"] as? String) {
            case .success(let l):
                out["result"] = ["content": [["type": "image", "data": l.png.base64EncodedString(), "mimeType": "image/png"],
                                             ["type": "text", "text": "\(l.width)×\(l.height) px. " + ScreenMarks.markSyntax]]]
            case .failure(let e): out["result"] = ["content": [["type": "text", "text": e.message]], "isError": true] as [String: Any]
            }
        default: out["error"] = ["code": -32601, "message": "Method not found"]
        }
        return (try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) }
    }

    struct LookError: Error { let message: String }

    private static var tool: [String: Any] { [
        "name": name,
        "description": "Take a screenshot of the user's screen right now and see it. Use only when the answer depends on what is on screen.",
        "inputSchema": ["type": "object", "properties": ["reason": ["type": "string", "description": "Why you need to look, in a few words."]], "additionalProperties": false] as [String: Any]] }
}
