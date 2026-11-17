import Foundation

/// The instruction that tells an assistant to save a summary of a conversation to your memory when it ends, and the code that puts it into
/// (and takes it out of) the global instruction files of the terminal agents. It only ever touches the lines between its own two markers.
enum AgentFiles {
    static let begin = "<!-- dex-memory:begin -->", end = "<!-- dex-memory:end -->"

    /// The same text is on the site's /connect page (a test keeps the two equal).
    static let block = """
        <!-- dex-memory:begin -->
        ## Dex memory
        At the end of a conversation, save it to the user's Dex memory so their other assistants can find it.
        - When the work is finished, or the user says thanks, goodbye or that they are done, call the `remember` tool once. It belongs to the Dex memory connector (`dex-memory`).
        - `title`: a few words. `content`: a short summary in markdown, not a transcript: what was decided, what was built or changed, facts worth keeping, and open questions. `source`: `claude` if you are Claude, `chatgpt` if you are ChatGPT, otherwise `other`.
        - Never include passwords, API keys, tokens or personal data.
        - Skip it if the user asked you not to save, if the conversation was trivial, or if you have no `remember` tool. Do not mention the tool unless it fails. When it works, say "Saved to your memory." in one line.
        <!-- dex-memory:end -->
        """

    struct Target: Equatable, Sendable, Hashable {
        var label: String        // who reads the file
        var tool: String         // the folder that exists when the tool is installed
        var file: String         // the global instruction file, relative to the home folder
    }
    static let targets = [Target(label: "Claude Code", tool: ".claude", file: ".claude/CLAUDE.md"),
                          Target(label: "Codex", tool: ".codex", file: ".codex/AGENTS.md"),
                          Target(label: "Gemini", tool: ".gemini", file: ".gemini/GEMINI.md")]

    static func has(_ text: String) -> Bool { text.contains(begin) && text.contains(end) }

    /// Adds the block at the end (or replaces an older copy of it in place). Everything else in the file is left exactly as it was.
    static func adding(to text: String) -> String {
        if let r = range(in: text) { return text.replacingCharacters(in: r, with: block + (text[r].hasSuffix("\n") ? "\n" : "")) }
        let base = text.isEmpty ? "" : (text.hasSuffix("\n") ? text : text + "\n") + (text.hasSuffix("\n\n") ? "" : "\n")
        return base + block + "\n"
    }

    static func removing(from text: String) -> String {
        guard let r = range(in: text) else { return text }
        var out = text.replacingCharacters(in: r, with: "")
        while out.hasSuffix("\n\n") { out.removeLast() }           // the blank line the block came with
        return out == "\n" ? "" : out
    }

    private static func range(in text: String) -> Range<String.Index>? {
        guard let a = text.range(of: begin), let b = text.range(of: end, range: a.upperBound..<text.endIndex) else { return nil }
        return a.lowerBound..<(text[b.upperBound...].hasPrefix("\n") ? text.index(after: b.upperBound) : b.upperBound)
    }

    // MARK: files

    static func installed(_ t: Target, home: URL) -> Bool { FileManager.default.fileExists(atPath: home.appendingPathComponent(t.tool).path) }
    static func enabled(_ t: Target, home: URL) -> Bool {
        (try? String(contentsOf: home.appendingPathComponent(t.file), encoding: .utf8)).map(has) ?? false
    }

    /// Writes the file whole and atomically. The first time a file is changed, the original is kept next to it as `.dex-backup`.
    static func set(_ on: Bool, _ t: Target, home: URL) throws {
        let url = home.appendingPathComponent(t.file), fm = FileManager.default
        let old = fm.fileExists(atPath: url.path) ? try String(contentsOf: url, encoding: .utf8) : ""
        let new = on ? adding(to: old) : removing(from: old)
        if new == old { return }
        let backup = url.appendingPathExtension("dex-backup")
        if fm.fileExists(atPath: url.path), !fm.fileExists(atPath: backup.path) { try fm.copyItem(at: url, to: backup) }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try new.write(to: url, atomically: true, encoding: .utf8)
    }
}
