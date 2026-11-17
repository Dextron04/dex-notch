import Foundation

/// The places an assistant can reach your memory from.
enum Surface: String, CaseIterable, Sendable {
    case claude, chatgpt, claudeCode, codex

    var name: String { switch self { case .claude: "Claude"; case .chatgpt: "ChatGPT"; case .claudeCode: "Claude Code"; case .codex: "Codex" } }
    var anchor: String { switch self { case .claude: "claude"; case .chatgpt: "chatgpt"; case .claudeCode: "claude-code"; case .codex: "codex" } }
    /// A terminal tool Dex Notch can add the connection to itself. The others are set up in the assistant's own settings.
    var isCLI: Bool { self == .claudeCode || self == .codex }
}

enum Conn: Equatable, Sendable {
    case connected, needsSignIn, missing
    case unknown            // couldn't tell (offline, tool not run): never a reason to nag
}

struct ConnectionReport: Equatable, Sendable {
    var states: [Surface: Conn]
    var checked: Date
    func state(_ s: Surface) -> Conn { states[s] ?? .unknown }
}

/// Reading what the `claude` and `codex` tools and the server say, and deciding when the notch should speak up. No UI, no processes: all of it is testable.
enum ConnectionLogic {
    static let serverName = "dex-memory"
    /// Once someone has been told about a missing connection, they aren't told again for this long.
    static let every: TimeInterval = 3 * 86_400

    static func mcpURL(host: String) -> String { "https://\(host)/mcp" }
    static func guideURL(host: String, _ s: Surface) -> URL? { URL(string: "https://\(host)/connect#\(s.anchor)") }

    /// The server's own answer (`/v1/me`): which web assistants hold a live authorization.
    static func parseAssistants(_ d: Data) -> (claude: Bool, chatgpt: Bool)? {
        guard let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], let a = o["assistants"] as? [String: Any] else { return nil }
        return ((a["claude"] as? Bool) ?? false, (a["chatgpt"] as? Bool) ?? false)
    }

    static func web(_ on: Bool?) -> Conn { on.map { $0 ? .connected : .missing } ?? .unknown }

    /// `claude mcp list` prints one line per server: `name: https://host/mcp - ✔ Connected`. This includes the connectors added on claude.ai, which Claude Code shares.
    static func parseClaudeList(_ out: String, host: String) -> Conn {
        for raw in out.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            guard let r = line.range(of: "https://") else { continue }
            let rest = String(line[r.lowerBound...])
            let target = rest.components(separatedBy: " - ").first ?? rest
            guard URL(string: target.trimmingCharacters(in: .whitespaces))?.host?.lowercased() == host.lowercased() else { continue }
            let status = String(rest.dropFirst(target.count))
            if status.contains("Connected") && !status.contains("Failed") { return .connected }
            if status.lowercased().contains("auth") { return .needsSignIn }
            return .unknown
        }
        return .missing
    }

    /// `codex mcp list --json`: an array of servers, each with a transport (an `url` for a web one) and an `auth_status`.
    static func parseCodex(_ d: Data, host: String) -> Conn {
        guard let all = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] else { return .unknown }
        for e in all {
            guard let t = e["transport"] as? [String: Any], let u = t["url"] as? String, URL(string: u)?.host?.lowercased() == host.lowercased() else { continue }
            if (e["enabled"] as? Bool) == false { return .missing }
            return ((e["auth_status"] as? String) ?? "").lowercased().contains("not_logged") ? .needsSignIn : .connected
        }
        return .missing
    }

    /// Which missing connection (if any) deserves a card at the notch now: only for things this Mac has, never twice inside `every`, never on a guess.
    static func nudge(_ r: ConnectionReport, installed: Set<Surface>, nudged: [String: Date], now: Date, remind: Bool) -> Surface? {
        guard remind else { return nil }
        for s in Surface.allCases where installed.contains(s) {
            guard r.state(s) == .missing || r.state(s) == .needsSignIn else { continue }
            if let t = nudged[s.rawValue], now.timeIntervalSince(t) < every { continue }
            return s
        }
        return nil
    }

    static func cardText(_ s: Surface, _ c: Conn) -> (headline: String, reason: String) {
        switch (s, c) {
        case (.claudeCode, .needsSignIn): return ("Claude Code needs to sign in to your memory", "Open Claude Code, type /mcp and choose dex-memory.")
        case (.codex, .needsSignIn): return ("Codex needs to sign in to your memory", "Settings → Memory opens the sign-in for you.")
        case (.claudeCode, _), (.codex, _): return ("\(s.name) isn't connected to your memory", "Settings → Memory can add it for you in one click.")
        default: return ("\(s.name) isn't connected to your memory", "Add it once and it can search what your other assistants learned. About a minute.")
        }
    }

    static func detail(_ s: Surface, _ c: Conn, here: Bool) -> String {
        switch c {
        case .connected: return "Connected."
        case .needsSignIn: return s.isCLI ? "Added, but not signed in yet." : "Needs you to sign in again."
        case .missing: return s.isCLI && !here ? "Not installed on this Mac." : "Not connected to your memory."
        case .unknown: return here || !s.isCLI ? "Couldn't check just now." : "Not installed on this Mac."
        }
    }
}
