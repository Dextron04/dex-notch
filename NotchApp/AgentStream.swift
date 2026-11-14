import Foundation

enum Backend: String, Codable { case gemma, claude, codex }
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

    /// Folders `⌘F` offers besides the scratch sandbox (names under the home directory).
    static let folders = ["Desktop", "Downloads", "Documents", "Projects"]
    static func nextFolder(_ current: String?) -> String? {
        guard let c = current, let i = folders.firstIndex(of: c) else { return folders[0] } // nil or unknown → first folder
        return i + 1 < folders.count ? folders[i + 1] : nil
    }

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
            guard let src = r["source"] as? String, src.hasPrefix("vault:"), let text = r["snippet"] as? String, !text.isEmpty else { continue }
            let path = String(src.dropFirst(6))
            guard perNote[path, default: 0] < 2 else { continue }
            perNote[path, default: 0] += 1
            out.append(Snippet(title: (r["title"] as? String) ?? path, source: path, snippet: text))
            if out.count == 5 { break }
        }
        return out
    }

    /// Appended to Gemma's system prompt. Empty when nothing was found, so plain questions stay plain.
    static func memoryPrompt(_ s: [Snippet], limit: Int = 3000) -> String {
        guard !s.isEmpty else { return "" }
        var body = "", n = 0
        for x in s {
            let month = x.source.split(separator: "/").first { $0.range(of: #"^\d{4}-\d{2}$"#, options: .regularExpression) != nil }.map(String.init) ?? ""
            let entry = "[\(n + 1)] \(x.title)\(month.isEmpty ? "" : " (" + month + ")"): \(x.snippet)\n"
            if body.count + entry.count > limit { body += String(entry.prefix(max(limit - body.count, 0))); break }
            body += entry; n += 1
        }
        return "Notes from the user's long-term memory (past conversations with their AI agents). Use them when they bear on the question and say which note you used. "
            + "If they don't answer it, say so; do not invent details beyond them.\n\n" + body
    }

    private static func object(_ line: String) -> [String: Any]? {
        guard let d = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }
}
