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
    var vaultLocked: Bool? = nil     // nil = the server didn't say
    var uploaded: Bool? = nil        // the first conversations from a Mac have arrived
    var used: Bool? = nil            // an assistant has used the memory at least once
    func state(_ s: Surface) -> Conn { states[s] ?? .unknown }
}

/// Reading what the `claude` and `codex` tools and the server say, and deciding when the notch should speak up. No UI, no processes: all of it is testable.
enum ConnectionLogic {
    static let serverName = "dex-memory"
    /// Once someone has been told about a missing connection, they aren't told again for this long.
    static let every: TimeInterval = 3 * 86_400

    static func mcpURL(host: String) -> String { "https://\(host)/mcp" }
    /// claude.ai's own "add a custom connector" dialog, opened with the name and address already filled in. The person reviews it and confirms there.
    /// The connector then shows up in Claude Code on the same account.
    static func addToClaudeURL(host: String) -> URL? {
        let value = mcpURL(host: host).addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        return URL(string: "https://claude.ai/customize/connectors?modal=add-custom-connector&connectorName=Dex%20Memory&connectorUrl=\(value)")
    }
    static func guideURL(host: String, _ s: Surface) -> URL? { URL(string: "https://\(host)/connect#\(s.anchor)") }

    /// The server's own answer (`/v1/me`): who holds a live authorization, and how far along the account is.
    struct ServerView: Equatable, Sendable {
        var claude: Bool, chatgpt: Bool, codex: Bool
        var vault: Bool?, uploaded: Bool?, used: Bool?
    }

    static func parseAssistants(_ d: Data) -> ServerView? {
        guard let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], let a = o["assistants"] as? [String: Any] else { return nil }
        let p = o["progress"] as? [String: Any]
        return ServerView(claude: (a["claude"] as? Bool) ?? false, chatgpt: (a["chatgpt"] as? Bool) ?? false, codex: (a["codex"] as? Bool) ?? false,
                          vault: o["vault_locked"] as? Bool, uploaded: p?["uploaded"] as? Bool, used: p?["used"] as? Bool)
    }
    /// The account page, at the passphrase form.
    static func lockURL(host: String) -> URL? { URL(string: "https://\(host)/account#vault-title") }

    // MARK: getting started

    enum Step: String, CaseIterable, Sendable { case vault, record, connect, firstChat }

    /// What a new tester should do next, in order. nil when there is nothing left. A step the server can't confirm is not nagged about.
    static func nextStep(vault: Bool?, recording: Bool, uploaded: Bool?, connected: Bool?, used: Bool?) -> Step? {
        if vault == false { return .vault }
        if !recording && uploaded != true { return .record }
        if connected == false { return .connect }
        if used == false { return .firstChat }
        return nil
    }

    static func stepText(_ s: Step?) -> (title: String, detail: String, button: String) {
        switch s {
        case .vault?: return ("Lock your vault", "Create a passkey, or use a passphrase. Your notes are encrypted with a key only you can open.", "Lock my vault")
        case .record?: return ("Start recording", "Dex Notch saves your Claude Code, Codex and Gemini conversations and uploads them to your account.", "Start recording")
        case .connect?: return ("Connect Claude or ChatGPT", "So they can search what you've saved, and save to it.", "Add in Claude")
        case .firstChat?: return ("Have your first conversation", "Paste this into Claude or ChatGPT, then ask the other one to find it.", "Copy the first line")
        case nil: return ("You're all set", "Ask any assistant: \"Search my Dex memory for …\"", "")
        }
    }

    static let firstPrompt = "Remember this for me: I'm trying out Dex Memory, and my favorite color is amber."
    static let secondPrompt = "Search my Dex memory: what did I say my favorite color was?"
    /// The account page, at the passphrase form.

    static func web(_ on: Bool?) -> Conn { on.map { $0 ? .connected : .missing } ?? .unknown }

    /// `claude mcp list` prints one line per server: `name: https://host/mcp - ✔ Connected`. This includes the connectors added on claude.ai, which Claude Code shares.
    static func parseClaudeList(_ out: String, host: String) -> Conn {
        for raw in out.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            guard let r = line.range(of: "https://") else { continue }
            let rest = String(line[r.lowerBound...])
            let target = rest.prefix { !$0.isWhitespace }          // the address is the first word; "(HTTP)" and " - status" follow it
            guard URL(string: String(target))?.host?.lowercased() == host.lowercased() else { continue }
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

    /// The two rows Settings shows. Claude includes Claude Code (it uses the connectors on your Claude account); ChatGPT includes Codex.
    static let rows: [Surface] = [.claude, .chatgpt]

    /// Whether this Mac has anything for a row: the app, or the terminal tool that belongs with it.
    static func here(_ row: Surface, _ installed: Set<Surface>) -> Bool {
        row == .claude ? installed.contains(.claude) || installed.contains(.claudeCode) : installed.contains(.chatgpt) || installed.contains(.codex)
    }

    /// One state and one sentence for a row, from the pieces behind it.
    static func rollUp(_ row: Surface, _ r: ConnectionReport?, installed: Set<Surface>) -> (state: Conn, detail: String) {
        guard let r else { return (.unknown, "Checking…") }
        if row == .claude {
            let web = r.state(.claude), cli = installed.contains(.claudeCode) ? r.state(.claudeCode) : Conn.unknown
            if web == .connected || cli == .connected { return (.connected, "Connected." + (installed.contains(.claudeCode) ? " Claude Code uses the same connection." : "")) }
            if web == .missing || cli == .missing { return (.missing, "Not connected to your memory.") }
            if cli == .needsSignIn { return (.needsSignIn, "Needs you to sign in again.") }
            return (.unknown, "Couldn't check just now.")
        }
        let web = r.state(.chatgpt), hasCodex = installed.contains(.codex), codex = hasCodex ? r.state(.codex) : Conn.connected     // no Codex here: nothing more to add
        switch (web, codex) {
        case (.connected, .connected): return (.connected, "Connected." + (hasCodex ? " Codex too." : ""))
        case (.connected, .unknown): return (.connected, "Connected in ChatGPT. Couldn't check Codex just now.")
        case (.connected, .needsSignIn): return (.needsSignIn, "Codex is added but needs you to sign in.")
        case (.connected, _): return (.missing, "Connected in ChatGPT. Codex still needs adding.")
        case (.missing, .missing): return (.missing, "Not connected to your memory.")
        case (.missing, .needsSignIn): return (.needsSignIn, "Codex needs you to sign in. ChatGPT isn't connected either.")
        case (.missing, _): return (.missing, hasCodex && codex == .connected ? "Codex is connected. ChatGPT isn't yet." : "Not connected in ChatGPT.")
        case (.unknown, .connected): return hasCodex ? (.connected, "Codex is connected. Couldn't check ChatGPT just now.") : (.unknown, "Couldn't check just now.")
        case (.unknown, .needsSignIn): return (.needsSignIn, "Codex is added but needs you to sign in.")
        case (.unknown, .missing): return (.missing, "Codex still needs adding. Couldn't check ChatGPT just now.")
        default: return (.unknown, "Couldn't check just now.")
        }
    }

    /// Which missing connection (if any) deserves a card at the notch now: only for things this Mac has, never twice inside `every`, never on a guess.
    static func nudge(_ r: ConnectionReport, installed: Set<Surface>, nudged: [String: Date], now: Date, remind: Bool) -> Surface? {
        guard remind else { return nil }
        for row in rows where here(row, installed) {
            let st = rollUp(row, r, installed: installed).state
            guard st == .missing || st == .needsSignIn else { continue }
            if let t = nudged[row.rawValue], now.timeIntervalSince(t) < every { continue }
            return row
        }
        return nil
    }

    static func cardText(_ s: Surface, _ c: Conn) -> (headline: String, reason: String) {
        switch (s, c) {
        case (.claude, _): return ("Claude isn't connected to your memory", "One click opens Claude with it ready to add. Claude Code picks it up from there.")
        case (.chatgpt, .needsSignIn): return ("Codex needs to sign in to your memory", "Settings → Memory opens the sign-in for you.")
        default: return ("\(s.name) isn't connected to your memory", "Add it once and it can search what your other assistants learned. About a minute.")
        }
    }

    static func detail(_ s: Surface, _ c: Conn, here: Bool) -> String {
        switch c {
        case .connected: return "Connected."
        case .needsSignIn: return s == .codex ? "Added, but not signed in yet." : "Needs you to sign in again."
        case .missing: return s.isCLI && !here ? "Not installed on this Mac." : "Not connected to your memory."
        case .unknown: return here || !s.isCLI ? "Couldn't check just now." : "Not installed on this Mac."
        }
    }
}
