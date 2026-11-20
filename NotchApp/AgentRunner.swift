import Foundation

/// Launches the `claude` / `codex` CLIs headless (your subscription, the official clients) and streams parsed events.
enum AgentRunner {
    struct Missing: Error { let name: String }

    /// Casual questions run here, so Read/Grep see nothing by default and `@claude+` edits land in a throwaway folder.
    static let scratch: URL = {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchApp/scratch", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(u.path, 0o700)      // already there from an older version: screenshots land here
        return u
    }()

    /// A Finder-launched app has a bare PATH; ask a login shell for the real one (once).
    private static let loginPATH: String = {
        let p = Process(), out = makePipe()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "printf %s \"$PATH\""]
        p.standardOutput = out; p.standardError = FileHandle.nullDevice
        try? p.run()
        let s = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return s.isEmpty ? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" : s
    }()

    private static func find(_ name: String) -> String? {
        AgentStream.locate(name, inPATH: loginPATH) { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Where a tool lives, found the way the notch finds `claude` and `codex` (a Finder-launched app has no PATH of its own).
    static func locate(_ name: String) -> String? { find(name) }
    static var environment: [String: String] { var e = ProcessInfo.processInfo.environment; e["PATH"] = loginPATH; return e }

    /// Which CLIs are installed. Logged-in is only discovered when one is run (the error then says so).
    static func available() -> Set<Backend> {
        if let o = AgentStream.parseCLIOverride(ProcessInfo.processInfo.environment["NOTCH_CLIS"]) { return o }
        return Set([Backend.claude, .codex].filter { find($0.rawValue) != nil })
    }

    /// A one-shot "the process ended" signal. `Process.waitUntilExit` blocks a pool thread on a run loop and, with several runs at once (Both), sometimes never returns.
    private final class Exit: @unchecked Sendable {
        private let l = NSLock(); private var done = false; private var cont: CheckedContinuation<Void, Never>?
        func fire() { l.lock(); done = true; let c = cont; cont = nil; l.unlock(); c?.resume() }
        func wait() async { await withCheckedContinuation { c in l.lock(); if done { l.unlock(); c.resume() } else { cont = c; l.unlock() } } }
    }
    private static let pipeLock = NSLock()

    /// Foundation leaves a new pipe's fds inheritable, so a run started while another one's pipe exists held that pipe open: the first run's output did not
    /// end until the second exited (Claude's stream waited for Codex). Close-on-exec from birth on both ends (the child still gets its own copy by dup2).
    private static func makePipe() -> Pipe {
        pipeLock.lock(); defer { pipeLock.unlock() }
        let p = Pipe()
        for h in [p.fileHandleForReading, p.fileHandleForWriting] { _ = fcntl(h.fileDescriptor, F_SETFD, FD_CLOEXEC) }
        return p
    }

    /// The lines a process writes, one per newline, ending at EOF. Not `FileHandle.bytes`: its reads share one blocking queue, so a run whose output had ended
    /// still waited for another run's pending read (Claude's stream did not finish until Codex wrote or exited). A readability handler is a source per handle.
    static func lines(of h: FileHandle) -> AsyncStream<String> {
        AsyncStream { cont in
            final class Buf: @unchecked Sendable { var d = Data() }      // only touched by this handle's handler, which dispatch runs one at a time
            let b = Buf()
            h.readabilityHandler = { fh in
                let d = fh.availableData
                if d.isEmpty {
                    fh.readabilityHandler = nil
                    if !b.d.isEmpty { cont.yield(String(decoding: b.d, as: UTF8.self)) }
                    cont.finish(); return
                }
                b.d.append(d)
                while let i = b.d.firstIndex(of: 10) {
                    cont.yield(String(decoding: b.d[b.d.startIndex..<i], as: UTF8.self))
                    b.d.removeSubrange(b.d.startIndex...i)
                }
            }
            cont.onTermination = { _ in h.readabilityHandler = nil }
        }
    }

    static func run(_ route: Route, session: String?) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { cont in
            let work = Task.detached {
                let name = route.backend == .claude ? "claude" : "codex"
                guard let exe = find(name) else { cont.finish(throwing: Missing(name: name)); return }
                let p = Process(), out = makePipe()
                p.executableURL = URL(fileURLWithPath: exe)
                // Locked (mail) runs get a brand-new empty folder; the shared scratch folder is wiped of planted settings before every other run.
                var cwd = scratch, temp: [URL] = [], codexHome: URL?, env = ProcessInfo.processInfo.environment
                let realCodex = env["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
                defer {
                    if let h = codexHome { RunSpace.keepRefreshedAuth(from: h, to: realCodex) }
                    temp.forEach { try? FileManager.default.removeItem(at: $0) }
                }
                do {
                    if route.locked {
                        cwd = try RunSpace.freshRunDir(); temp.append(cwd)
                        if route.backend == .codex { let h = try RunSpace.codexTriageHome(realHome: realCodex); temp.append(h); codexHome = h; env["CODEX_HOME"] = h.path }
                    } else { RunSpace.scrub(scratch) }
                } catch { cont.finish(throwing: error); return }
                let mcp = AgentStream.agentvaultMCPConfig(claudeJSON: FileManager.default.contents(atPath: NSHomeDirectory() + "/.claude.json"))
                p.arguments = route.locked
                    ? (route.backend == .claude ? AgentStream.lockedClaudeArgs(prompt: route.prompt) : AgentStream.lockedCodexArgs(prompt: route.prompt))
                    : route.backend == .claude
                    ? AgentStream.claudeArgs(prompt: route.prompt, session: session, work: route.work, folder: route.folder, scratch: scratch.standardizedFileURL.path, mcpConfig: mcp, look: route.look)
                    : AgentStream.codexArgs(prompt: route.prompt, session: session, work: route.work, folder: route.folder, image: route.image, look: route.look)
                p.currentDirectoryURL = cwd
                env["PATH"] = loginPATH
                p.environment = env
                p.standardInput = FileHandle.nullDevice // codex otherwise waits on stdin
                p.standardOutput = out; p.standardError = FileHandle.nullDevice
                let exited = Exit(); p.terminationHandler = { _ in exited.fire() }
                do { try p.run() } catch { cont.finish(throwing: error); return }
                cont.onTermination = { _ in if p.isRunning { p.terminate() } }
                var any = false
                for await line in lines(of: out.fileHandleForReading) {
                    for e in route.backend == .claude ? AgentStream.claudeEvents(line: line) : AgentStream.codexEvents(line: line) {
                        any = true; cont.yield(e)
                    }
                }
                await exited.wait()
                if p.terminationStatus != 0 && !any { cont.finish(throwing: NSError(domain: name, code: Int(p.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: "\(name) exited with code \(p.terminationStatus). Is it logged in?"])); return }
                cont.finish()
            }
            cont.onTermination = { _ in work.cancel() }
        }
    }
}
