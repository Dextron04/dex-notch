import SwiftUI
import Observation

/// Runs a command-line tool and returns what it printed, or nil if it couldn't start or ran past `timeout`.
enum Probe {
    static func run(_ exe: String, _ args: [String], timeout: TimeInterval = 45, mergeErrors: Bool = false) -> String? {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: exe); p.arguments = args; p.environment = AgentRunner.environment
        p.currentDirectoryURL = AgentRunner.scratch
        p.standardInput = FileHandle.nullDevice; p.standardOutput = out; p.standardError = mergeErrors ? out : FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let stop = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: stop)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit(); stop.cancel()
        return p.terminationReason == .exit ? String(decoding: data, as: UTF8.self) : nil
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
    private var cli: [Surface: Conn] = [:]
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
            cli = await Task.detached { Self.probe(host: host, installed: here) }.value
            lastProbe = Date()
        }
        let web = await HostedAPI.assistants(host: host, token: token)
        var s: [Surface: Conn] = [.claude: ConnectionLogic.web(web?.claude), .chatgpt: ConnectionLogic.web(web?.chatgpt)]
        for (k, v) in cli { s[k] = v }
        let r = ConnectionReport(states: s, checked: Date()); report = r
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

    func connect(_ s: Surface) {
        guard let host else { return }
        note = nil
        if !s.isCLI {
            if let u = ConnectionLogic.guideURL(host: host, s) { NSWorkspace.shared.open(u) }
            note = "Add the connector in \(s.name) (the page that just opened has the steps), then press Check again."
            return
        }
        busy = s
        let mcp = ConnectionLogic.mcpURL(host: host)
        Task {
            let added = await Task.detached { Self.add(s, mcp: mcp) }.value
            note = added.message
            if s == .codex, added.ok { _ = await Task.detached { Self.login(.codex) }.value }       // opens the browser to sign in, and waits
            busy = nil
            await refresh(full: true)
        }
    }

    /// What a notch card's button does: the web ones open their guide, the terminal ones open Settings where the button is.
    func openFromCard(_ id: String) {
        let raw = id.split(separator: "|").dropFirst().first.map(String.init) ?? ""
        guard let s = Surface(rawValue: raw) else { return }
        if s.isCLI { openSettings?() } else if let host, let u = ConnectionLogic.guideURL(host: host, s) { NSWorkspace.shared.open(u) }
    }

    struct Added: Sendable { var ok: Bool; var message: String }

    nonisolated static func add(_ s: Surface, mcp: String) -> Added {
        let name = ConnectionLogic.serverName
        let (tool, args): (String, [String]) = s == .claudeCode ? ("claude", ["mcp", "add", "--transport", "http", "--scope", "user", name, mcp]) : ("codex", ["mcp", "add", name, "--url", mcp])
        guard let exe = AgentRunner.locate(tool) else { return Added(ok: false, message: "\(s.name) wasn't found on this Mac.") }
        let r = Probe.run(exe, args, timeout: 30, mergeErrors: true) ?? ""
        let first = r.split(whereSeparator: \.isNewline).first.map { String($0.prefix(140)) } ?? "no answer"
        let exists = r.lowercased().contains("already exists")
        let ok = exists || r.lowercased().contains("added") || (s == .codex && !r.lowercased().contains("error"))
        if !ok { return Added(ok: false, message: "\(s.name) said: \(first)") }
        return Added(ok: true, message: s == .claudeCode ? "Added to Claude Code. Open it, type /mcp, choose dex-memory and sign in." : "Added to Codex. Finish signing in in your browser.")
    }

    nonisolated static func login(_ s: Surface) -> Bool {
        guard s == .codex, let exe = AgentRunner.locate("codex") else { return false }
        return Probe.run(exe, ["mcp", "login", ConnectionLogic.serverName], timeout: 300, mergeErrors: true) != nil
    }
}
