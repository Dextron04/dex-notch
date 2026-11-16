import SwiftUI
import Observation

/// State + networking for the notch assistant. Talks to an Ollama server you configure (settings.json) over HTTPS, and runs the claude / codex CLIs.
@MainActor @Observable
final class Assistant {
    enum Link { case connecting, ready, offline }

    /// Gemma is optional: it exists only once settings.json names a host and model.
    private(set) var gemma: GemmaSettings?
    private(set) var gemmaProblem: String?       // a half-filled gemma section
    private(set) var settingsProblem: String?    // settings.json isn't valid JSON
    private var preferred: Backend?              // "default" from settings.json
    private(set) var workspaceDefault: String?   // workspace.default: the folder edit runs start with (nil = scratch sandbox)
    private var configuredFolders: [String]?     // workspace.folders (nil = the built-in four)
    private(set) var workspaceProblems: [String] = []
    private(set) var cliFound: Set<Backend> = [] // which of `claude` / `codex` are installed
    private(set) var detected = false            // false until the first look for them has finished

    /// The models on the dial: installed CLIs, plus Gemma when configured.
    var choices: [Backend] { AgentStream.order.filter { $0 == .gemma ? gemma != nil : cliFound.contains($0) } }
    var needsSetup: Bool { detected && choices.isEmpty }
    var configProblem: String? { settingsProblem ?? gemmaProblem ?? workspaceProblems.first }
    /// What ⌘F cycles through: configured folders that exist.
    var folderList: [String] {
        AgentStream.folderChoices(configured: configuredFolders, defaultFolder: workspaceDefault, home: FileManager.default.homeDirectoryForCurrentUser)
            .compactMap { Settings.normalizeFolder($0, home: FileManager.default.homeDirectoryForCurrentUser) { var d: ObjCBool = false; return FileManager.default.fileExists(atPath: $0, isDirectory: &d) && d.boolValue } }
    }
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
    var draft = "" {
        didSet { // "@claude " typed at the start becomes a dial choice instead of staying in the text
            if let c = AgentStream.consumePrefix(draft), !busy { backend = c.backend; work = c.work; draft = c.rest }
        }
    }
    var turns: [Turn] = []
    var waiting = false     // sent, no token yet
    var streaming = false   // tokens arriving
    var error: String?
    var backend: Backend = .claude  // who answers unprefixed questions in this conversation
    var work = false                // claude/codex may edit files and run commands — the "+" on the dial
    var folder: String?             // absolute path of the extra folder those runs may write to (nil = the scratch sandbox only)
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

    private var closedAt: Date?
    private var lastWarm: Date?
    private let storeURL: URL
    private let settingsURL: URL
    private var convID = UUID().uuidString
    private var journaled = 0                         // turns already written to the vault journal
    private var exchange: (backend: Backend, askedAt: Date) = (.claude, Date())

    init(storeURL: URL = ConversationStore.defaultURL, settingsURL: URL = Settings.defaultURL) {
        self.storeURL = storeURL; self.settingsURL = settingsURL
        loadSettings(); restore(); refreshAvailability()
    }

    /// Re-read on every connection check, so editing settings.json and pressing ⌥Space (or "Check connection") is enough.
    func loadSettings() {
        switch Settings.load(from: settingsURL) {
        case .ok(let a):
            if a.gemma != gemma { token = nil }
            gemma = a.gemma; gemmaProblem = a.gemmaProblem; settingsProblem = nil; preferred = a.defaultBackend
            workspaceDefault = a.workspaceDefault; configuredFolders = a.folders; workspaceProblems = a.workspaceProblems
        case .missing:
            gemma = nil; gemmaProblem = nil; settingsProblem = nil; preferred = nil
            workspaceDefault = nil; configuredFolders = nil; workspaceProblems = []
        case .invalid(let why):
            gemma = nil; gemmaProblem = nil; settingsProblem = why; preferred = nil
            workspaceDefault = nil; configuredFolders = nil; workspaceProblems = []
        }
        if let f = folder, !folderList.contains(f) { folder = workspaceDefault }   // the folder was removed from settings
        if folder == nil, turns.isEmpty { folder = workspaceDefault }
        settleBackend()
    }

    /// Looks for the `claude` and `codex` CLIs (off the main thread: asking a login shell for PATH takes a moment).
    func refreshAvailability() {
        Task {
            let found = await Task.detached { AgentRunner.available() }.value
            let first = !detected
            cliFound = found; detected = true
            let next = AgentStream.backendAfterDetection(current: backend, firstDetection: first, hasConversation: !turns.isEmpty, choices: choices, preferred: preferred)
            if next != backend { backend = next; if next == .gemma { work = false } }
        }
    }

    /// If the selected model isn't available (uninstalled, or Gemma was removed from settings), move to one that is.
    private func settleBackend() {
        guard !choices.isEmpty, !choices.contains(backend), let d = AgentStream.defaultBackend(choices: choices, preferred: preferred) else { return }
        backend = d; if d == .gemma { work = false }
    }

    /// Menu: "Set up Gemma…" — opens settings.json in the default text editor (creating a blank one first).
    func openSettings() {
        _ = try? Settings.ensureTemplate(at: settingsURL)
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/open"); p.arguments = ["-t", settingsURL.path]; try? p.run()
    }

    // MARK: persistence — the open conversation survives quitting the app

    func persist() {
        let c = SavedConversation(id: convID, turns: turns.map { SavedTurn(role: $0.role, text: $0.text) }, backend: backend, work: work, folder: folder,
                                  sessions: Dictionary(uniqueKeysWithValues: sessions.map { ($0.key.rawValue, $0.value) }),
                                  draft: draft, recalled: recalled, closedAt: closedAt ?? Date())
        try? ConversationStore.save(c, to: storeURL) // best effort: a full disk must never break the notch
    }

    private func restore() {
        guard let c = ConversationStore.load(from: storeURL) else { return }
        turns = c.turns.map { Turn(role: $0.role, text: $0.text) }
        backend = c.backend; work = c.work; recalled = c.recalled
        folder = c.folder.map { $0.hasPrefix("/") ? $0 : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent($0).path }  // older saves stored just "Desktop"
        sessions = Dictionary(uniqueKeysWithValues: c.sessions.compactMap { k, v in Backend(rawValue: k).map { ($0, v) } })
        closedAt = c.closedAt
        convID = c.id ?? convID; journaled = turns.count // restored turns were journaled when they happened
        draft = c.draft
    }

    private var task: Task<Void, Never>?
    private var summaryTask: Task<Void, Never>?
    private var token: String?

    var question: String? { turns.last(where: { $0.role == "user" })?.text }
    var answer: String { turns.last(where: { $0.role == "assistant" })?.text ?? "" }
    var busy: Bool { waiting || streaming }

    // MARK: open / close

    // MARK: model dial

    func setBackend(_ b: Backend) { guard !busy, choices.contains(b) else { return }; backend = b; if b == .gemma { work = false; warmLocalModel() } }
    func cycleBackend(_ d: Int) { setBackend(AgentStream.cycle(backend, by: d, among: choices)) }
    /// ⌘1 ⌘2 ⌘3 pick the 1st, 2nd, 3rd model that is actually on the dial.
    func setBackendAt(_ i: Int) { if choices.indices.contains(i) { setBackend(choices[i]) } }
    /// ⌘F: sandbox → Desktop → Downloads → Documents → Projects → sandbox. Picking a folder implies edit rights.
    func cycleFolder() { guard !busy, backend != .gemma else { return }; folder = AgentStream.nextFolder(folder, in: folderList); if folder != nil { work = true } }
    func toggleWork() { guard !busy, backend != .gemma else { return }; work.toggle() }

    func toggle() { if isOpen && mode == .prompt { close() } else { open(.prompt) } }
    func toggleRecall() { if isOpen && mode == .recall { close() } else { open(.recall) } }

    func open(_ m: Mode = .prompt) {
        NSLog("NotchApp: open %@ (already open: %d)", m == .prompt ? "ask" : "recall", isOpen ? 1 : 0)
        if isOpen && mode == m { return }
        mode = m
        if m == .recall { searching = false; recallQuery = ""; page = .chats; refreshRecall(); recallIndex = 0; summary = ""; cursor = max(grid.days.count - 1, 0); loadDay() }
        guard !isOpen else { return } // already open in the other mode: just switch content
        if !busy && AgentStream.isStale(closedAt: closedAt, now: Date()) { reset() } // away a long time: start fresh
        isOpen = true
        onOpenChange?(true)
        if link != .ready { connect() }
        if m == .prompt && backend == .gemma { warmLocalModel() }
    }

    func close() {
        NSLog("NotchApp: close (was open: %d)", isOpen ? 1 : 0)
        guard isOpen else { return }
        summaryTask?.cancel(); summarizing = false; summary = "" // recall-only state
        // The conversation is NOT cleared and a running answer is NOT cancelled: clicking away must never lose work.
        closedAt = Date()
        isOpen = false
        onOpenChange?(false)
        persist()
    }

    /// ⌘N / the new-chat button: drop the conversation (and stop a running answer) on purpose.
    func newConversation() { task?.cancel(); reset() }

    private func reset() { turns = []; draft = ""; error = nil; backend = AgentStream.defaultBackend(choices: choices, preferred: preferred) ?? .claude; work = false; folder = workspaceDefault; sessions = [:]; toolNote = nil; recalled = []; waiting = false; streaming = false; summary = ""; summarizing = false; convID = UUID().uuidString; journaled = 0; persist() }

    // MARK: ask

    func send() {
        let q = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !busy else { return }
        var r = AgentStream.route(q)
        if r.prompt == q { r.backend = backend; r.work = work && backend != .gemma } // no prefix: use the dial
        else { backend = r.backend; work = r.work }                                  // pasted "@claude …" switches the dial
        guard !r.prompt.isEmpty else { draft = ""; return } // bare "@claude": just switch
        if r.work, let f = folder {                         // `+` run with a chosen folder: grant write access to exactly that one, re-checked now
            let home = FileManager.default.homeDirectoryForCurrentUser
            r.folder = Settings.normalizeFolder(f, home: home) { var d: ObjCBool = false; return FileManager.default.fileExists(atPath: $0, isDirectory: &d) && d.boolValue }
        }
        let b = r.backend
        exchange = (b, Date())
        draft = ""; error = nil; toolNote = nil; recalled = []
        turns.append(Turn(role: "user", text: r.prompt))
        turns.append(Turn(role: "assistant", text: ""))
        waiting = true
        persist() // the question is safe even if the app dies mid-answer

        let messages = [["role": "system", "content": Self.system]]
            + turns.dropLast().map { ["role": $0.role, "content": $0.text] }

        task = Task {
            do {
                if b == .gemma {
                    var messages = messages
                    let hits = await vaultRecall(r.prompt)
                    recalled = hits.reduce(into: [String]()) { if !$0.contains($1.title) { $0.append($1.title) } }
                    let overview = AgentStream.wantsOverview(r.prompt) ? VaultReader.overview(vault: VaultReader.defaultVault) : nil
                    if overview != nil { recalled.insert("vault overview", at: 0) }
                    messages[0]["content"] = Self.system + "\n\n" + AgentStream.memoryPrompt(hits, overview: overview)   // the briefing goes in every time
                    try await streamChat(messages) { t in
                        guard !turns.isEmpty else { return }
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
        guard let g = gemma else { throw Failure(gemmaProblem ?? settingsProblem ?? "Gemma isn't set up. Choose “Settings…” in the menu bar.") }
        let tok = try loadToken()
        var req = URLRequest(url: URL(string: g.base + "/api/chat")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 300 // first call may load the model into memory
        req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: AgentStream.gemmaChatBody(model: g.model, messages: messages))
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

    /// One-shot, non-streaming call to the local model (add-on triage).
    func askGemma(system: String, user: String) async throws -> String {
        var out = ""
        try await streamChat([["role": "system", "content": system], ["role": "user", "content": user]]) { out += $0 }
        return out
    }

    /// Asks the mini's RAG which vault notes bear on the question. Never blocks the answer: any failure just means no context.
    private func vaultRecall(_ question: String) async -> [Snippet] {
        let keywords = AgentStream.keywordQuery(question)
        async let plain = searchVault(question)
        async let focused = keywords == question ? [] : searchVault(keywords)       // filler-free version: finds notes a vague question misses
        return AgentStream.mergeSnippets(await plain, await focused)
    }

    private func searchVault(_ question: String) async -> [Snippet] {
        guard let g = gemma, let tok = try? loadToken() else { return [] }
        var req = URLRequest(url: URL(string: g.base + "/rag/search")!)
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
            guard !turns.isEmpty else { return } // ⌘N during an answer can empty the list under us
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
        defer { persist() }
        waiting = false; streaming = false; toolNote = nil
        if turns.last?.role == "assistant", turns.last?.text.isEmpty == true, error != nil { turns.removeLast() }
        journalGemmaExchange()
    }

    /// Gemma has no session log of its own, so each finished exchange goes to the vault journal (claude/codex runs are already
    /// recorded from their own logs). Skipped on errors and cancels: only a complete question + answer is worth remembering.
    private func journalGemmaExchange() {
        defer { journaled = turns.count }
        guard exchange.backend == .gemma, error == nil, turns.count > journaled, turns.count >= 2,
              turns[turns.count - 1].role == "assistant", !turns[turns.count - 1].text.isEmpty, turns[turns.count - 2].role == "user" else { return }
        try? Journal.append([JournalEntry(role: "user", text: turns[turns.count - 2].text, ts: exchange.askedAt),
                             JournalEntry(role: "assistant", text: turns[turns.count - 1].text, ts: Date())],
                            conv: convID, model: "gemma", to: Journal.defaultDir) // best effort: never block the notch on disk trouble
    }

    struct Failure: Error { let msg: String; init(_ m: String) { msg = m } }
    private func friendly(_ e: Error) -> String {
        let n = e as NSError
        if n.domain == NSURLErrorDomain, n.code == NSURLErrorCannotConnectToHost || n.code == NSURLErrorNetworkConnectionLost {
            return "Can't reach \(gemma?.host ?? "the Gemma host")."
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
    var currentVisible: Int { page == .activity ? daySessions.count : RecallView.maxRows }

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
        guard let g = gemma else { link = .offline; throw Failure(gemmaProblem ?? settingsProblem ?? "Gemma isn't set up. Choose “Settings…” in the menu bar.") }
        guard let t = KeychainStore.get(service: g.keychainService, account: g.keychainAccount) else {   // via `security`: never prompts
            link = .offline
            throw Failure("No token in the Keychain (service \(g.keychainService), account \(g.keychainAccount)). Add it in Settings…")
        }
        token = t
        return t
    }

    /// Loads the model in the background while you type, so the first question isn't a minute-long cold start. Best effort.
    func warmLocalModel() {
        guard let g = gemma, AgentStream.shouldWarm(last: lastWarm, now: Date()), let tok = try? loadToken() else { return }
        lastWarm = Date()
        Task.detached {
            var r = URLRequest(url: URL(string: g.base + "/api/generate")!)
            r.httpMethod = "POST"; r.timeoutInterval = 150
            r.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization"); r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try? JSONSerialization.data(withJSONObject: AgentStream.gemmaWarmBody(model: g.model))
            _ = try? await URLSession.shared.data(for: r)
        }
    }

    /// Checks gateway reachability + token validity; drives the status dot.
    func connect() {
        loadSettings(); refreshAvailability()
        Task {
            link = .connecting
            guard let g = gemma else { link = .offline; return }
            guard let tok = try? loadToken() else { return } // loadToken set .offline
            var r = URLRequest(url: URL(string: g.base + "/api/tags")!)
            r.timeoutInterval = 6
            r.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
            let code = (try? await URLSession.shared.data(for: r).1 as? HTTPURLResponse)?.statusCode
            if code == 401 { token = nil } // stale token: reload next time
            link = code == 200 ? .ready : .offline
        }
    }
}
