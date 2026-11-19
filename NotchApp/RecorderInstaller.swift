import SwiftUI
import Observation

/// Puts the bundled recorder in place and runs it as a background job. One button in Settings → Memory, and once automatically after sign-up
/// (the welcome window says so), so a new tester needs nothing but the app.
@MainActor @Observable
final class RecorderInstaller {
    static let shared = RecorderInstaller()
    private(set) var status: RecorderLogic.Status = .notInstalled
    private(set) var busy = false
    var note: String?

    private let fm = FileManager.default
    private var home: URL { fm.homeDirectoryForCurrentUser }
    private var memoryDir: URL { home.appendingPathComponent("Library/Application Support/Dex Notch/memory", isDirectory: true) }
    private var plistURL: URL { home.appendingPathComponent("Library/LaunchAgents/\(RecorderLogic.label).plist") }
    private var vault: URL { home.appendingPathComponent("Vault", isDirectory: true) }
    private var marker: URL { memoryDir.appendingPathComponent(".app-version") }
    private var bundled: URL? { Bundle.main.resourceURL?.appendingPathComponent("recorder/agentvault") }
    private var backfillLog: URL { memoryDir.deletingLastPathComponent().appendingPathComponent("backfill.log") }
    private var uid: String { String(getuid()) }

    func refresh() {
        Task {
            let running = await Task.detached { Self.isRunning(uid: String(getuid())) }.value
            let py = await Task.detached { Self.findPython() != nil }.value
            status = RecorderLogic.status(plistText: try? String(contentsOf: plistURL, encoding: .utf8), memoryDir: memoryDir.path, running: running, python: py)
        }
    }

    /// Installs (or refreshes) the recorder. Does nothing to a recorder someone set up themselves.
    func install(backfill: Bool = true) {
        guard !busy else { return }
        busy = true; note = nil
        Task {
            defer { busy = false }
            // look at the file now, not at what was cached: a developer's own recorder must never be overwritten
            let existing = try? String(contentsOf: plistURL, encoding: .utf8)
            if case .elsewhere(let d) = RecorderLogic.status(plistText: existing, memoryDir: memoryDir.path, running: false, python: true) { status = .elsewhere(d); note = "A recorder is already set up to run from \(d). Leaving it alone."; return }
            guard let py = await Task.detached(operation: { () -> String? in Self.findPython() }).value else { status = .needsPython; note = RecorderLogic.text(.needsPython); return }
            guard let src = bundled, fm.fileExists(atPath: src.path) else { note = "This build has no recorder inside. Download the latest release."; return }
            do {
                try fm.createDirectory(at: memoryDir, withIntermediateDirectories: true)
                let dest = memoryDir.appendingPathComponent("agentvault")
                try RecorderLogic.swapIn(src, to: dest)       // the old recorder stays until the new copy is complete
                try fm.createDirectory(at: vault.appendingPathComponent(".recorder"), withIntermediateDirectories: true)
                try fm.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try RecorderLogic.plist(python: py, memoryDir: memoryDir.path, vault: vault.path).write(to: plistURL, atomically: true, encoding: .utf8)
                try AppUpdater.shared.version.write(to: marker, atomically: true, encoding: .utf8)
            } catch { note = "Couldn't set up the recorder: \(error.localizedDescription)"; return }
            let plist = plistURL.path, id = uid, mem = memoryDir.path, vaultPath = vault.path, logURL = backfillLog
            await Task.detached {
                _ = Probe.run("/bin/launchctl", ["bootout", "gui/\(id)/\(RecorderLogic.label)"], timeout: 15, mergeErrors: true)
                _ = Probe.run("/bin/launchctl", ["bootstrap", "gui/\(id)", plist], timeout: 15, mergeErrors: true)
                if backfill { Self.backfill(python: py, memoryDir: mem, vault: vaultPath, log: logURL) }     // your existing history, once
            }.value
            try? await Task.sleep(for: .seconds(2))
            let up = await Task.detached { Self.isRunning(uid: id) }.value
            note = up ? "Recording. Your conversations are saved to \(vaultPath) and uploaded to your account."
                      : "Installed, but it didn't start. The log is at \(vaultPath)/.recorder/recorder.log."
            refresh()
        }
    }

    /// After an app update, the recorder the app carries may be newer than the one running.
    func updateIfNeeded() {
        guard case .running = status, RecorderLogic.needsUpdate(installed: try? String(contentsOf: marker, encoding: .utf8), app: AppUpdater.shared.version) else { return }
        install(backfill: false)
    }

    func stop() {
        let id = uid
        Task.detached { _ = Probe.run("/bin/launchctl", ["bootout", "gui/\(id)/\(RecorderLogic.label)"], timeout: 15, mergeErrors: true) }
        note = "Stopped. Nothing is being recorded until you turn it on again."
        Task { try? await Task.sleep(for: .seconds(1)); refresh() }
    }

    nonisolated static func isRunning(uid: String) -> Bool {
        guard let out = Probe.run("/bin/launchctl", ["print", "gui/\(uid)/\(RecorderLogic.label)"], timeout: 10, mergeErrors: true) else { return false }
        return out.contains("state = running")
    }

    /// A python3 that can run the recorder (3.9 or newer). Apple's own /usr/bin/python3 is only a prompt to install the command line tools until they are there.
    nonisolated static func findPython() -> String? {
        guard let exe = AgentRunner.locate("python3") else { return nil }
        if exe == "/usr/bin/python3", Probe.run("/usr/bin/xcode-select", ["-p"], timeout: 10) == nil { return nil }
        guard let v = Probe.run(exe, ["-c", "import sys; print(int(sys.version_info >= (3, 9)))"], timeout: 15), v.trimmingCharacters(in: .whitespacesAndNewlines) == "1" else { return nil }
        return exe
    }

    /// Backfill's output goes to a log (appended, owner-only) so a failed import can be looked at; /dev/null told no one anything.
    nonisolated static func backfill(python: String, memoryDir: String, vault: String, log: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: python); p.arguments = ["-m", "agentvault", "backfill", "--vault", vault]
        p.currentDirectoryURL = URL(fileURLWithPath: memoryDir); p.environment = AgentRunner.environment
        let fm = FileManager.default
        if !fm.fileExists(atPath: log.path) { fm.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        if let h = try? FileHandle(forWritingTo: log) {
            _ = try? h.seekToEnd(); h.write(Data("\n--- backfill \(Date()) ---\n".utf8))
            p.standardOutput = h; p.standardError = h
        } else { p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice }
        try? p.run()                                            // it finishes on its own; the recorder job is already watching for new turns
    }
}
