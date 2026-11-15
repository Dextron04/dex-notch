import Foundation

enum Backend: String, Codable {
    case gemma, claude, codex
    /// What people (and VoiceOver) call it. `gemma` is the self-hosted Ollama connector, whatever model it serves.
    var displayName: String { switch self { case .gemma: "Local model"; case .claude: "Claude"; case .codex: "Codex" } }
}
struct Route: Equatable { var backend: Backend; var work: Bool; var prompt: String; var folder: String? = nil } // folder: absolute path `+` runs may also write to
struct Snippet: Equatable { var title: String; var source: String; var snippet: String }
enum AgentEvent: Equatable { case text(String), tool(String), session(String), final(String), error(String) }

/// Pure helpers for driving the `claude` / `codex` CLIs headless: prefix routing, argv, and stream-json parsing.
enum AgentStream {
    /// "@claude q" / "@claude+ q" / "@codex q" / "@codex+ q" pick a CLI (`+` = may edit files). Anything else is Gemma.
    static func route(_ input: String) -> Route {
        let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("@") else { return Route(backend: .gemma, work: false, prompt: t) }
        let word = t.prefix { !$0.isWhitespace }
        let name = word.dropFirst().lowercased()
        let work = name.hasSuffix("+")
        guard let b = Backend(rawValue: work ? String(name.dropLast()) : name), b != .gemma || !work else {
            return Route(backend: .gemma, work: false, prompt: t)
        }
        return Route(backend: b, work: work && b != .gemma, prompt: t.dropFirst(word.count).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// A conversation survives closing the notch; it only starts fresh after this long away (or on ⌘N).
    static func isStale(closedAt: Date?, now: Date, after: TimeInterval = 1800) -> Bool {
        closedAt.map { now.timeIntervalSince($0) > after } ?? false
    }

    /// ⌘F: scratch sandbox → each configured folder → back to the sandbox.
    static func nextFolder(_ current: String?, in list: [String]) -> String? {
        guard !list.isEmpty else { return nil }
        guard let c = current, let i = list.firstIndex(of: c) else { return list[0] }   // nil, or a folder no longer listed: start over
        return i + 1 < list.count ? list[i + 1] : nil
    }

    /// The folders an edit run can be granted: the configured list (or the four standard ones), plus the default workspace.
    static func folderChoices(configured: [String]?, defaultFolder: String?, home: URL) -> [String] {
        var list = configured ?? ["Desktop", "Downloads", "Documents", "Projects"].map { home.path + "/" + $0 }
        if let d = defaultFolder, !list.contains(d) { list.append(d) }
        return list
    }

    static func folderLabel(_ path: String?) -> String { path.map { ($0 as NSString).lastPathComponent } ?? "sandbox" }

    /// Which model starts selected: the one named in settings if it exists, else claude, codex, gemma in that order. nil = nothing usable yet.
    static func defaultBackend(choices: [Backend], preferred: Backend?) -> Backend? {
        if let p = preferred, choices.contains(p) { return p }
        return [Backend.claude, .codex, .gemma].first { choices.contains($0) }
    }

    /// What the dial should show after looking for the CLIs. The default applies once, on the very first look and only when no
    /// conversation is being restored; after that the user's own choice stands unless that model is gone.
    static func backendAfterDetection(current: Backend, firstDetection: Bool, hasConversation: Bool, choices: [Backend], preferred: Backend?) -> Backend {
        guard !choices.isEmpty else { return current }
        if firstDetection && !hasConversation { return defaultBackend(choices: choices, preferred: preferred) ?? current }
        return choices.contains(current) ? current : (defaultBackend(choices: choices, preferred: preferred) ?? current)
    }

    /// ⇥ over only the models that exist (the dial hides the rest).
    static func cycle(_ b: Backend, by d: Int, among list: [Backend]) -> Backend {
        guard !list.isEmpty else { return b }
        guard let i = list.firstIndex(of: b) else { return list[0] }
        return list[((i + d) % list.count + list.count) % list.count]
    }

    /// First executable called `name` in a PATH-style string. Empty entries are skipped (an empty PATH entry would otherwise mean "/name").
    static func locate(_ name: String, inPATH path: String, isExecutable: (String) -> Bool) -> String? {
        path.split(separator: ":", omittingEmptySubsequences: true).map { "\($0)/\(name)" }.first(where: isExecutable)
    }

    /// NOTCH_CLIS="none" | "claude,codex": pretend only these CLIs are installed (demos, screenshots, first-run testing). nil = no override.
    static func parseCLIOverride(_ raw: String?) -> Set<Backend>? {
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return Set(raw.split(separator: ",").compactMap { Backend(rawValue: $0.trimmingCharacters(in: .whitespaces).lowercased()) }.filter { $0 != .gemma })
    }

    // MARK: local model requests

    /// Ollama's `keep_alive`: how long the model stays in memory after a request. Without it the default (about 5 minutes) unloads
    /// an 8 GB model, and the next question waits most of a minute for it to load again.
    static let gemmaKeepAlive = "30m"
    static let gemmaMaxTokens = 1024      // a runaway answer must not hold the server's single slot for minutes

    static func gemmaChatBody(model: String, messages: [[String: String]]) -> [String: Any] {
        ["model": model, "messages": messages, "stream": true, "think": false, "keep_alive": gemmaKeepAlive,
         "options": ["num_predict": gemmaMaxTokens]]
    }

    /// POST /api/generate with a model and no prompt just loads it into memory.
    static func gemmaWarmBody(model: String) -> [String: Any] { ["model": model, "keep_alive": gemmaKeepAlive, "stream": false] }

    /// Refresh the loaded model shortly before its keep-alive would run out; never more often than that.
    static func shouldWarm(last: Date?, now: Date) -> Bool { last.map { now.timeIntervalSince($0) > 25 * 60 } ?? true }

    static let order: [Backend] = [.gemma, .claude, .codex]
    static func cycle(_ b: Backend, by d: Int) -> Backend {
        let n = order.count
        return order[((order.firstIndex(of: b) ?? 0) + d % n + n) % n]
    }
    /// "@claude " / "@codex+ text" typed at the start of the field: returns the choice and the remaining text so the UI can turn it into the dial.
    static func consumePrefix(_ draft: String) -> (backend: Backend, work: Bool, rest: String)? {
        guard draft.hasPrefix("@"), let sp = draft.firstIndex(where: \.isWhitespace) else { return nil } // no space yet = still typing the name
        let name = draft[draft.index(after: draft.startIndex)..<sp].lowercased()
        let edits = name.hasSuffix("+")
        guard let b = Backend(rawValue: edits ? String(name.dropLast()) : name) else { return nil }
        return (b, edits && b != .gemma, String(draft[sp...].drop { $0.isWhitespace }))
    }

    private static let brief = "You answer inside a tiny overlay beside the Mac's notch. Be brief and direct: plain sentences, no headings, no preamble."

    // MARK: argv

    /// Claude's own OS sandbox (seatbelt) for its shell: writes only inside the working folder (plus `folder`, if one was chosen),
    /// no network, and no way back to an unsandboxed shell.
    private static func claudeSandbox(folder: String?) -> String {
        var sb: [String: Any] = ["enabled": true, "autoAllowBashIfSandboxed": true, "allowUnsandboxedCommands": false]
        if let folder { sb["filesystem"] = ["allowWrite": [folder]] }
        let d = try? JSONSerialization.data(withJSONObject: ["sandbox": sb], options: [.withoutEscapingSlashes])
        return d.map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    static func claudeArgs(prompt: String, session: String?, work: Bool, folder: String? = nil) -> [String] {
        var a = ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages", "--append-system-prompt",
                 work ? brief + " You may edit files and run shell commands; commands run in a sandbox: they can only write inside the current folder and have no network." : brief]
        if let session { a += ["--resume", session] }
        // Ask: look things up only. Work (`+`): may also edit files and run commands, but only inside the sandbox above.
        a += ["--allowedTools", "Read", "Grep", "Glob", "WebSearch", "WebFetch", "mcp__agentvault"] + (work ? ["Edit", "Write", "Bash"] : [])
        if work { a += ["--permission-mode", "acceptEdits", "--settings", claudeSandbox(folder: folder)] }
        else { a += ["--disallowedTools", "Bash", "Edit", "Write", "NotebookEdit"] }
        return a + ["--", prompt] // `--`: variadic flags above must not swallow the prompt, and a leading "-" must not parse as an option
    }

    static func codexArgs(prompt: String, session: String?, work: Bool, folder: String? = nil) -> [String] {
        // sandbox flags go before `resume`: the subcommand doesn't take them
        ["exec", "--json", "--skip-git-repo-check", "--sandbox", work ? "workspace-write" : "read-only"]
            + (work ? folder.map { ["--add-dir", $0] } ?? [] : [])
            + (session.map { ["resume", $0] } ?? []) + [prompt]
    }

    // MARK: stream parsing (one JSON object per line)

    static func claudeEvents(line: String) -> [AgentEvent] {
        guard let j = object(line), let type = j["type"] as? String else { return [] }
        switch type {
        case "system":
            return (j["subtype"] as? String) == "init" ? (j["session_id"] as? String).map { [.session($0)] } ?? [] : []
        case "stream_event":
            guard let e = j["event"] as? [String: Any] else { return [] }
            if e["type"] as? String == "content_block_delta", let d = e["delta"] as? [String: Any],
               d["type"] as? String == "text_delta", let t = d["text"] as? String { return [.text(t)] }
            if e["type"] as? String == "content_block_start", let b = e["content_block"] as? [String: Any],
               b["type"] as? String == "tool_use", let n = b["name"] as? String { return [.tool(n)] }
            return []
        case "result":
            let text = (j["result"] as? String) ?? ""
            let sid: [AgentEvent] = (j["session_id"] as? String).map { [.session($0)] } ?? []
            return sid + [(j["is_error"] as? Bool) == true ? .error(text) : .final(text)]
        default: return []
        }
    }

    static func codexEvents(line: String) -> [AgentEvent] {
        guard let j = object(line), let type = j["type"] as? String else { return [] }
        let item = j["item"] as? [String: Any]
        switch type {
        case "thread.started": return (j["thread_id"] as? String).map { [.session($0)] } ?? []
        case "turn.failed": return [.error(((j["error"] as? [String: Any])?["message"] as? String) ?? "Codex failed")]
        case "error": return [.error((j["message"] as? String) ?? "Codex failed")]
        case "item.completed" where item?["type"] as? String == "agent_message":
            return (item?["text"] as? String).map { [.text($0)] } ?? []
        case "item.started":
            switch item?["type"] as? String {
            case "command_execution": return [.tool("shell")]
            case "web_search": return [.tool("web search")]
            case "mcp_tool_call": return [.tool((item?["tool"] as? String) ?? "tool")]
            case "file_change": return [.tool("editing")]
            default: return []
            }
        default: return [] // incl. item.completed "error" items: those are config warnings, not failures
        }
    }

    // MARK: vault recall (what the mini's /rag/search returns → context for Gemma)

    /// Vault chunks from a /rag/search response: vault notes only, at most 2 per note and 5 overall (one long note must not crowd out the rest).
    static func parseSnippets(_ data: Data) -> [Snippet] {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let rows = j["sources"] as? [[String: Any]] else { return [] }
        var perNote: [String: Int] = [:], out: [Snippet] = []
        for r in rows {
            guard let src = r["source"] as? String, src.hasPrefix("vault:"), !src.hasPrefix("vault:Sessions/gemma/"), let text = r["snippet"] as? String, !text.isEmpty else { continue }
            let path = String(src.dropFirst(6))
            guard perNote[path, default: 0] < 2 else { continue }
            perNote[path, default: 0] += 1
            out.append(Snippet(title: (r["title"] as? String) ?? path, source: path, snippet: text))
            if out.count == 5 { break }
        }
        return out
    }

    /// Appended to Gemma's system prompt. Empty when nothing was found, so plain questions stay plain.
    /// Questions about time, or about the vault itself, can't be answered by similarity search ("today" matches nothing),
    /// so they get an overview of what is actually in the vault.
    static func wantsOverview(_ q: String) -> Bool {
        let t = q.lowercased()
        let cues = ["today", "yesterday", "tonight", "this week", "last week", "lately", "recent", "last conversation", "last chat", "last session",
                    "just now", "been doing", "what did i do", "what have i", "my vault", "the vault", "my memory", "my notes", "what do you know",
                    "what can you do", "how does the memory", "how do you use", "what's in", "what is in", "whats in"]
        return cues.contains { t.contains($0) }
    }

    /// The question with filler words removed, for the search's keyword half. Falls back to the original when too little is left.
    static func keywordQuery(_ q: String) -> String {
        let filler: Set<String> = ["what", "did", "we", "do", "does", "is", "are", "was", "were", "the", "a", "an", "about", "of", "for", "to", "in", "on", "my",
                                   "me", "i", "you", "your", "our", "and", "or", "with", "how", "why", "when", "where", "which", "who", "that", "this", "it",
                                   "its", "be", "been", "have", "has", "had", "can", "could", "should", "would", "will", "just", "please", "tell", "show", "give"]
        let words = q.split(whereSeparator: { !($0.isLetter || $0.isNumber || "_@+-./".contains($0)) })
            .map(String.init).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".-/")) }.filter { !$0.isEmpty && !filler.contains($0.lowercased()) }
        return words.count >= 2 ? words.joined(separator: " ") : q
    }

    /// Results of the plain search first, then anything new from the keyword search. Same limits as one search: two per note, six in all.
    static func mergeSnippets(_ a: [Snippet], _ b: [Snippet], max: Int = 6) -> [Snippet] {
        var seen = Set<String>(), perNote: [String: Int] = [:], out: [Snippet] = []
        for x in a + b {
            let key = x.source + "|" + String(x.snippet.prefix(60))
            guard seen.insert(key).inserted, perNote[x.source, default: 0] < 2 else { continue }
            perNote[x.source, default: 0] += 1; out.append(x)
            if out.count == max { break }
        }
        return out
    }

    static let vaultBriefing = "You are connected to the user's memory vault: Obsidian notes of their past conversations with AI agents (Claude Code, Codex, Gemini, ChatGPT and you). "
        + "Notes that match the question, and sometimes an overview of the vault, are included below. When the question is about the user's own work or history, answer from them and name the note you used. "
        + "Use a note only if it is clearly about the question; ignore the ones that are not. If none clearly answer it, say you couldn't find it in the vault; do not invent details, notes or dates beyond what is shown. For general questions, just answer."

    /// Added to Gemma's system prompt on every question, so it always knows what the vault is and the rules for using it.
    static func memoryPrompt(_ s: [Snippet], overview: String? = nil, limit: Int = 3000) -> String {
        var out = vaultBriefing
        if let o = overview, !o.isEmpty { out += "\n\nVault overview:\n" + o }
        guard !s.isEmpty else { return out + "\n\nNo notes matched this question." }
        var body = "", n = 0
        for x in s {
            let month = x.source.split(separator: "/").first { $0.range(of: #"^\d{4}-\d{2}$"#, options: .regularExpression) != nil }.map(String.init) ?? ""
            let entry = "[\(n + 1)] \(x.title)\(month.isEmpty ? "" : " (" + month + ")"): \(x.snippet)\n"
            if body.count + entry.count > limit { body += String(entry.prefix(max(limit - body.count, 0))); break }
            body += entry; n += 1
        }
        return out + "\n\nNotes:\n" + body
    }

    private static func object(_ line: String) -> [String: Any]? {
        guard let d = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }
}
