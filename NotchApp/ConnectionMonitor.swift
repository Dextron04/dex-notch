import SwiftUI
import Observation

/// Runs a command-line tool and returns what it printed, or nil if it couldn't start or ran past `timeout`.
enum Probe {
    static func run(_ exe: String, _ args: [String], timeout: TimeInterval = 90, mergeErrors: Bool = false) -> String? {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: exe); p.arguments = args; p.environment = AgentRunner.environment
        p.currentDirectoryURL = AgentRunner.scratch
        p.standardInput = FileHandle.nullDevice; p.standardOutput = out; p.standardError = mergeErrors ? out : FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let stop = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: stop)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit(); stop.cancel()
        let text = String(decoding: data, as: UTF8.self)
        return p.terminationReason == .exit || !text.isEmpty ? text : nil      // cut off at the timeout: whatever it had printed is still worth reading
    }
}

/// Keeps an eye on whether your assistants are connected to your memory. The server says which web assistants (Claude, ChatGPT) hold an authorization;
/// the `claude` and `codex` tools say whether the terminal ones have the connector. When something this Mac has is missing, it asks the notch to say so, once in a while.
@MainActor @Observable
final class ConnectionMonitor {
    static let shared = ConnectionMonitor()

    private(set) var report: ConnectionReport?
    private(set) var installed: Set<Surface> = []
    private(set) var checking = false
    private(set) var busy: Surface?
    var note: String?
    /// Which terminal agents have the "save at the end of a conversation" instruction in their global file.
    private(set) var instructions: Set<AgentFiles.Target> = []
    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    /// The notch's side: show a card for this missing connection.
    var onMissing: ((Surface, Conn) -> Void)?
    /// How a card's button opens Settings.
    var openSettings: (() -> Void)?

    private let url = Settings.defaultURL
    private var loop: Task<Void, Never>?
    private var lastProbe: Date?
    private var cli: [Surface: Conn] = [:]          // the last answer the terminal tools gave: a failed look does not erase it
    private static let nudgedKey = "connectNudged"

    var host: String? { HostedAccount.connectedHost(at: url) }

    /// "connections": { "remind": false } in settings.json turns the cards off. On by default.
    var remind: Bool {
        guard let d = try? Data(contentsOf: url), let root = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return true }
        return ((root["connections"] as? [String: Any])?["remind"] as? Bool) != false
    }
    func setRemind(_ on: Bool) {
        do { try Settings.mutate(at: url) { root in var c = (root["connections"] as? [String: Any]) ?? [:]; c["remind"] = on; root["connections"] = c } }
        catch { note = "Couldn't save settings.json: \(error.localizedDescription)" }
    }

    /// A look soon after launch, then every half hour (the server is asked each time; the terminal tools only every six hours, because listing starts every server you have).
    func start() {
        loop?.cancel()
        loop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(45))
            while !Task.isCancelled { await self?.refresh(nudge: true); try? await Task.sleep(for: .seconds(1800)) }
        }
    }

    /// `full`: run the terminal tools now (the Check again button). Otherwise they are re-run only when six hours old.
    func refresh(full: Bool = false, nudge: Bool = false) async {
        guard !checking, let host, let token = KeychainStore.get(service: HostedAccount.keychainService, account: HostedAccount.keychainAccount) else { return }
        checking = true; defer { checking = false }
        let here = await Task.detached { Self.findInstalled() }.value
        installed = here
        if full || lastProbe.map({ Date().timeIntervalSince($0) > 6 * 3600 }) ?? true {
            let fresh = await Task.detached { Self.probe(host: host, installed: here) }.value
            for (k, v) in fresh where v != .unknown { cli[k] = v }
            if fresh.values.contains(where: { $0 != .unknown }) || here.isDisjoint(with: [.claudeCode, .codex]) { lastProbe = Date() }      // a look that found nothing is tried again at the next check
        }
        let web = await HostedAPI.assistants(host: host, token: token)
        var s: [Surface: Conn] = [.claude: ConnectionLogic.web(web?.claude), .chatgpt: ConnectionLogic.web(web?.chatgpt)]
        for (k, v) in cli { s[k] = v }
        if cli[.codex] == nil || cli[.codex] == .unknown { s[.codex] = web?.codex == true ? .connected : (cli[.codex] ?? .unknown) }     // the tool said nothing: the server knows if Codex holds a live sign-in
        let r = ConnectionReport(states: s, checked: Date(), vaultLocked: web?.vault, uploaded: web?.uploaded, used: web?.used); report = r
        guard nudge else { return }
        var nudged = (UserDefaults.standard.dictionary(forKey: Self.nudgedKey) as? [String: Date]) ?? [:]
        if let missing = ConnectionLogic.nudge(r, installed: here, nudged: nudged, now: Date(), remind: remind) {
            nudged[missing.rawValue] = Date(); UserDefaults.standard.set(nudged, forKey: Self.nudgedKey)
            onMissing?(missing, r.state(missing))
        }
    }

    nonisolated static func findInstalled() -> Set<Surface> {
        var s: Set<Surface> = []
        let clis = AgentRunner.available()
        if clis.contains(.claude) { s.insert(.claudeCode) }
        if clis.contains(.codex) { s.insert(.codex) }
        let apps = ["/Applications", NSHomeDirectory() + "/Applications"]
        if apps.contains(where: { FileManager.default.fileExists(atPath: $0 + "/Claude.app") }) { s.insert(.claude) }
        if apps.contains(where: { FileManager.default.fileExists(atPath: $0 + "/ChatGPT.app") }) { s.insert(.chatgpt) }
        return s
    }

    nonisolated static func probe(host: String, installed: Set<Surface>) -> [Surface: Conn] {
        var out: [Surface: Conn] = [:]
        if installed.contains(.claudeCode), let exe = AgentRunner.locate("claude"), let r = Probe.run(exe, ["mcp", "list"]) { out[.claudeCode] = ConnectionLogic.parseClaudeList(r, host: host) }
        if installed.contains(.codex), let exe = AgentRunner.locate("codex"), let r = Probe.run(exe, ["mcp", "list", "--json"]) { out[.codex] = ConnectionLogic.parseCodex(Data(r.utf8), host: host) }
        return out
    }

    // MARK: the instruction that saves a conversation when it ends

    func refreshInstructions() { instructions = Set(AgentFiles.targets.filter { AgentFiles.enabled($0, home: home) }) }
    /// The agents on this Mac that have a global instruction file to put it in.
    var agentsHere: [AgentFiles.Target] { AgentFiles.targets.filter { AgentFiles.installed($0, home: home) } }
    var instructionsOn: Bool { !agentsHere.isEmpty && agentsHere.allSatisfy { instructions.contains($0) } }

    /// One button: on for every agent found, or off again for all of them.
    func toggleInstructions() {
        let on = !instructionsOn
        do {
            for t in agentsHere { try AgentFiles.set(on, t, home: home) }
            note = on ? "On. New conversations in \(agentsHere.map(\.label).joined(separator: ", ")) will save a summary to your memory." : "Off."
        } catch { note = "Couldn't change the instruction file: \(error.localizedDescription)" }
        refreshInstructions()
    }

    // MARK: the buttons

    /// Opens the account page at the passphrase form: the one step that has to happen in the browser, because the passphrase never passes through the app.
    func lockVault() {
        guard let host, let u = ConnectionLogic.lockURL(host: host) else { return }
        NSWorkspace.shared.open(u)
        note = "Choose a passphrase on the page that opened, save the recovery code, then press Check again."
    }

    /// One button per row. Claude: Claude's own add-a-connector dialog, ready filled in (Claude Code shares it). ChatGPT: its steps in the browser (ChatGPT has no prefilled link),
    /// and, when Codex is here and not connected, the same click adds it to Codex too: ChatGPT on the web doesn't pass connectors on to Codex.
    func connect(_ row: Surface) {
        guard let host else { return }
        note = nil
        if row == .claude || row == .claudeCode {
            if let u = ConnectionLogic.addToClaudeURL(host: host) { NSWorkspace.shared.open(u) }
            note = "Claude opened with Dex Memory ready to add. Confirm it there, sign in and allow, then press Check again." + (installed.contains(.claudeCode) ? " Claude Code picks it up from your Claude account." : "")
            return
        }
        let web = report?.state(.chatgpt) != .connected, codex = installed.contains(.codex) && report?.state(.codex) != .connected
        var said: [String] = []
        if web {
            if let u = ConnectionLogic.guideURL(host: host, .chatgpt) { NSWorkspace.shared.open(u) }
            said.append("ChatGPT's steps opened in your browser. Add the connector there.")
        }
        guard codex else { note = (said + ["Then press Check again."]).joined(separator: " "); return }
        busy = .chatgpt
        let mcp = ConnectionLogic.mcpURL(host: host), before = said
        Task {
            let added = await Task.detached { Self.add(.codex, mcp: mcp) }.value
            note = (before + [added.message]).joined(separator: " ")
            if added.ok && added.needsLogin { _ = await Task.detached { Self.login(.codex) }.value }       // only if the add didn't already sign in
            busy = nil
            await refresh(full: true)
        }
    }

    /// What a notch card's button does: the web ones open their guide, the terminal ones open Settings where the button is.
    func openFromCard(_ id: String) {
        let raw = id.split(separator: "|").dropFirst().first.map(String.init) ?? ""
        guard let s = Surface(rawValue: raw) else { return }
        guard let host else { return }
        if s == .claude { if let u = ConnectionLogic.addToClaudeURL(host: host) { NSWorkspace.shared.open(u) } }
        else if report?.state(.chatgpt) == .missing, let u = ConnectionLogic.guideURL(host: host, .chatgpt) { NSWorkspace.shared.open(u) }
        else { openSettings?() }                                            // only Codex is left: the button that adds it is in Settings
    }

    struct Added: Sendable { var ok: Bool; var message: String; var needsLogin = false }

    /// `codex mcp add` already starts the browser sign-in and waits for it, so it gets as long as a person needs. Its own words tell us what happened.
    nonisolated static func add(_ s: Surface, mcp: String) -> Added {
        guard let exe = AgentRunner.locate("codex") else { return Added(ok: false, message: "Codex wasn't found on this Mac.") }
        let r = Probe.run(exe, ["mcp", "add", ConnectionLogic.serverName, "--url", mcp], timeout: 300, mergeErrors: true) ?? ""
        let low = r.lowercased(), lines = r.split(whereSeparator: \.isNewline).map { String($0.prefix(160)) }
        if low.contains("successfully logged in") { return Added(ok: true, message: "Added to Codex and signed in.") }
        if let err = lines.first(where: { $0.lowercased().hasPrefix("error") }) { return Added(ok: false, message: "Codex said: \(err)") }
        if low.contains("already exists") || low.contains("added") { return Added(ok: true, message: "Added to Codex. Finish signing in in your browser.", needsLogin: true) }
        return Added(ok: false, message: "Codex said: \(lines.first ?? "nothing")")
    }

    nonisolated static func login(_ s: Surface) -> Bool {
        guard s == .codex, let exe = AgentRunner.locate("codex") else { return false }
        return Probe.run(exe, ["mcp", "login", ConnectionLogic.serverName], timeout: 300, mergeErrors: true) != nil
    }
}
