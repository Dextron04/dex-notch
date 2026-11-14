import SwiftUI
import Observation

/// State + networking for the notch assistant. Talks to Ollama on the mac-mini over HTTPS via the cloudflare gateway.
@MainActor @Observable
final class Assistant {
    enum Link { case connecting, ready, offline }

    static let model = "gemma3:12b"
    static let host = "ai.example.com"   // cloudflare tunnel -> caddy gateway on the mac-mini (bearer token)
    private static let base = "https://\(host)"
    private static let keychainService = host // token lives in the login keychain: service=host, account=notchapp
    private static let system = "You answer inside a tiny overlay beside the Mac's notch. Be brief and direct: plain sentences, no headings, no preamble. Use short lists only when asked. Put any code in fenced blocks with a language tag."

    struct Turn { var role: String; var text: String }

    enum Mode { case prompt, recall }
    enum RecallPage: Int, CaseIterable {
        case chats, activity, projects
        var label: String { ["Last chats", "Activity", "Projects"][rawValue] }
    }

    var isOpen = false
    var mode: Mode = .prompt
    var link: Link = .connecting
    var draft = ""
    var turns: [Turn] = []
    var waiting = false     // sent, no token yet
    var streaming = false   // tokens arriving
    var error: String?
    var backend: Backend = .gemma   // who answers unprefixed questions in this conversation
    var recalled: [String] = []     // titles of the vault notes Gemma was handed for the last answer
    var toolNote: String?           // what claude/codex is doing right now ("Read", "shell", …)
    private var sessions: [Backend: String] = [:] // CLI session ids so follow-ups resume the same conversation

    /// Called whenever isOpen flips so the window can take/release key focus.
    var onOpenChange: ((Bool) -> Void)?

    // recall view state
    var page: RecallPage = .chats
    var grid = ActivityGrid(days: [], agents: [], cells: [:], maxCount: 0)
    var cursor = 0                       // selected day on the Activity page (index into grid.days)
    var daySessions: [AgentSummary] = []
    var projectStats: [ProjectStat] = []
    var snapshot = VaultSnapshot(totalSessions: 0, todayCount: 0, recorderOK: false, agents: [])
    var recallRows: [AgentSummary] = []
    var recallIndex = 0
    var searching = false
    var recallQuery = "" { didSet { refreshRecall() } }
    var summary = ""
    var summarizing = false

    private var task: Task<Void, Never>?
    private var summaryTask: Task<Void, Never>?
    private var token: String?

    var question: String? { turns.last(where: { $0.role == "user" })?.text }
    var answer: String { turns.last(where: { $0.role == "assistant" })?.text ?? "" }
    var busy: Bool { waiting || streaming }

    // MARK: open / close

    func toggle() { if isOpen && mode == .prompt { close() } else { open(.prompt) } }
    func toggleRecall() { if isOpen && mode == .recall { close() } else { open(.recall) } }

    func open(_ m: Mode = .prompt) {
        if isOpen && mode == m { return }
        mode = m
        if m == .recall { searching = false; recallQuery = ""; page = .chats; refreshRecall(); recallIndex = 0; summary = ""; cursor = max(grid.days.count - 1, 0); loadDay() }
        guard !isOpen else { return } // already open in the other mode: just switch content
        isOpen = true
        onOpenChange?(true)
        if link != .ready { connect() }
    }

    func close() {
        guard isOpen else { return }
        task?.cancel(); summaryTask?.cancel()
        isOpen = false
        onOpenChange?(false)
        // clear after the collapse animation so the content doesn't snap away mid-close
        Task { try? await Task.sleep(for: .milliseconds(450)); if !isOpen { reset() } }
    }

    private func reset() { turns = []; draft = ""; error = nil; backend = .gemma; sessions = [:]; toolNote = nil; recalled = []; waiting = false; streaming = false; summary = ""; summarizing = false }

    // MARK: ask

    func send() {
        let q = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !busy else { return }
        var r = AgentStream.route(q)
        if r.prompt == q { r.backend = backend }       // no prefix: stay on the model this conversation started with
        else { backend = r.backend }                   // "@claude" switches (sticky until the notch closes)
        guard !r.prompt.isEmpty else { draft = ""; return } // bare "@claude": just switch
        let b = r.backend
        draft = ""; error = nil; toolNote = nil; recalled = []
        turns.append(Turn(role: "user", text: r.prompt))
        turns.append(Turn(role: "assistant", text: ""))
        waiting = true

        let messages = [["role": "system", "content": Self.system]]
            + turns.dropLast().map { ["role": $0.role, "content": $0.text] }

        task = Task {
            do {
                if b == .gemma {
                    var messages = messages
                    let hits = await vaultRecall(r.prompt)
                    recalled = hits.reduce(into: [String]()) { if !$0.contains($1.title) { $0.append($1.title) } }
                    let extra = AgentStream.memoryPrompt(hits)
                    if !extra.isEmpty { messages[0]["content"] = Self.system + "\n\n" + extra }
                    try await streamChat(messages) { t in
                        waiting = false; streaming = true
                        turns[turns.count - 1].text += t
                    }
                } else {
                    try await runAgent(r)
                }
                finish()
            } catch is CancellationError {
                finish()
            } catch {
                if Task.isCancelled { return }
                self.error = (error as? Failure)?.msg ?? friendly(error)
                finish()
            }
        }
    }

    /// POSTs a chat to the gateway and calls `onToken` for every streamed piece of the reply.
    private func streamChat(_ messages: [[String: String]], onToken: (String) -> Void) async throws {
        let tok = try loadToken()
        var req = URLRequest(url: URL(string: Self.base + "/api/chat")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 300 // first call may load the model into memory
        req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject:
            ["model": Self.model, "messages": messages, "stream": true, "think": false] as [String: Any])
        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        if let code = (resp as? HTTPURLResponse)?.statusCode, code != 200 {
            throw Failure(code == 401 ? "Gateway rejected the token. Re-store it in Keychain." : "Model returned HTTP \(code)")
        }
        for try await line in bytes.lines {
            guard let d = line.data(using: .utf8),
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            if let e = j["error"] as? String { throw Failure(e) }
            if let t = (j["message"] as? [String: Any])?["content"] as? String, !t.isEmpty { onToken(t) }
            if j["done"] as? Bool == true { break }
        }
    }

    /// Asks the mini's RAG which vault notes bear on the question. Never blocks the answer: any failure just means no context.
    private func vaultRecall(_ question: String) async -> [Snippet] {
        guard let tok = try? loadToken() else { return [] }
        var req = URLRequest(url: URL(string: Self.base + "/rag/search")!)
        req.httpMethod = "POST"; req.timeoutInterval = 5
        req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["messages": [["role": "user", "content": question]]])
        guard let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return AgentStream.parseSnippets(data)
    }

    /// Streams a `claude` / `codex` CLI run into the last assistant turn; `toolNote` shows what it is doing.
    private func runAgent(_ r: Route) async throws {
        var gotText = false, needBreak = false
        func add(_ t: String) {
            waiting = false; streaming = true; toolNote = nil
            if needBreak, !turns[turns.count - 1].text.isEmpty { turns[turns.count - 1].text += "\n\n" }
            needBreak = false; gotText = true
            turns[turns.count - 1].text += t
        }
        do {
            for try await e in AgentRunner.run(r, session: sessions[r.backend]) {
                switch e {
                case .session(let s): sessions[r.backend] = s
                case .text(let t): add(t)
                case .tool(let n): toolNote = n; needBreak = true
                case .final(let t): if !gotText { add(t) }
                case .error(let m): throw Failure(m)
                }
            }
        } catch let m as AgentRunner.Missing { throw Failure("`\(m.name)` not found. Install it and log in.") }
    }

    private func finish() {
        waiting = false; streaming = false; toolNote = nil
        if turns.last?.role == "assistant", turns.last?.text.isEmpty == true, error != nil { turns.removeLast() }
    }

    struct Failure: Error { let msg: String; init(_ m: String) { msg = m } }
    private func friendly(_ e: Error) -> String {
        let n = e as NSError
        if n.domain == NSURLErrorDomain, n.code == NSURLErrorCannotConnectToHost || n.code == NSURLErrorNetworkConnectionLost {
            return "Can't reach \(Self.host)."
        }
        return e.localizedDescription
    }

    // MARK: recall (vault browser)

    func refreshRecall() {
        snapshot = VaultReader.snapshot(vault: VaultReader.defaultVault)
        recallRows = searching && !recallQuery.isEmpty ? VaultReader.search(vault: VaultReader.defaultVault, query: recallQuery) : snapshot.agents
        grid = VaultReader.activity(vault: VaultReader.defaultVault, days: 70)
        projectStats = VaultReader.projects(vault: VaultReader.defaultVault, limit: 6)
        cursor = min(max(cursor, 0), max(grid.days.count - 1, 0))
        recallIndex = min(recallIndex, max(min(recallRows.count, RecallView.maxRows) - 1, 0))
    }

    /// The rows ↑/↓/↩ act on: day sessions on the Activity page, otherwise the chat list.
    var currentRows: [AgentSummary] { page == .activity ? daySessions : recallRows }
    var currentVisible: Int { page == .activity ? RecallView.maxDayRows : RecallView.maxRows }

    func setPage(_ p: RecallPage) { page = p; recallIndex = 0; summary = ""; summaryTask?.cancel(); summarizing = false; if p == .activity { loadDay() } }
    func stepPage(_ d: Int) { let n = RecallPage.allCases.count; setPage(RecallPage(rawValue: ((page.rawValue + d) % n + n) % n)!) }

    func moveCursor(_ d: Int) { setCursor(cursor + d) }
    func setCursor(_ i: Int) { cursor = min(max(i, 0), max(grid.days.count - 1, 0)); recallIndex = 0; summary = ""; loadDay() }
    func loadDay() { daySessions = grid.days.indices.contains(cursor) ? VaultReader.sessions(on: grid.days[cursor], vault: VaultReader.defaultVault) : [] }

    func moveSelection(_ d: Int) {
        guard !currentRows.isEmpty else { return }
        recallIndex = VaultReader.moveIndex(recallIndex, by: d, rows: currentRows.count, visible: currentVisible)
        summaryTask?.cancel(); summary = ""; summarizing = false
    }

    func openSelectedNote() {
        guard currentRows.indices.contains(recallIndex) else { return }
        let note = currentRows[recallIndex].notePath
        var c = URLComponents(string: "obsidian://open")!
        c.queryItems = [URLQueryItem(name: "path", value: note.path)]
        // Obsidian only resolves notes inside a vault it knows (open ~/Vault in Obsidian once); otherwise fall back to the default .md app
        if let u = c.url, NSWorkspace.shared.urlForApplication(toOpen: u) != nil { NSWorkspace.shared.open(u) } else { NSWorkspace.shared.open(note) }
    }

    /// ⌘↩: three-line summary of the selected note from the model.
    func summarizeSelected() {
        guard currentRows.indices.contains(recallIndex), !summarizing,
              var text = try? String(contentsOf: currentRows[recallIndex].notePath, encoding: .utf8) else { return }
        if text.count > 4000 { text = String(text.prefix(2000)) + "\n…\n" + String(text.suffix(2000)) } // long notes are slow to read on the mini
        summary = ""; summarizing = true
        let messages = [["role": "system", "content": "Summarize this recorded agent conversation in at most three short lines: what was asked, what was done or decided, what is left. Plain text, no preamble."],
                        ["role": "user", "content": text]]
        summaryTask?.cancel()
        summaryTask = Task {
            do { try await streamChat(messages) { if !Task.isCancelled { summary += $0 } } }
            catch is CancellationError { return }
            catch { if !Task.isCancelled { summary = (error as? Failure)?.msg ?? friendly(error) } }
            if !Task.isCancelled { summarizing = false } // a cancelled task must not clear the flag of the one that replaced it
        }
    }

    // MARK: connection

    /// Reads the bearer token from the login keychain via `security` (the tool that stored it, so no prompt).
    private func loadToken() throws -> String {
        if let token { return token }
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", Self.keychainService, "-a", "notchapp", "-w"]
        p.standardOutput = out; p.standardError = FileHandle.nullDevice
        try? p.run(); p.waitUntilExit()
        let t = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard p.terminationStatus == 0, !t.isEmpty else {
            link = .offline
            throw Failure("No API token in Keychain for \(Self.host).")
        }
        token = t
        return t
    }

    /// Checks gateway reachability + token validity; drives the status dot.
    func connect() {
        Task {
            link = .connecting
            guard let tok = try? loadToken() else { return } // loadToken set .offline
            var r = URLRequest(url: URL(string: Self.base + "/api/tags")!)
            r.timeoutInterval = 6
            r.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
            let code = (try? await URLSession.shared.data(for: r).1 as? HTTPURLResponse)?.statusCode
            if code == 401 { token = nil } // stale token: reload next time
            link = code == 200 ? .ready : .offline
        }
    }
}
