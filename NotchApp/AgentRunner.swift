import Foundation

/// Launches the `claude` / `codex` CLIs headless (your subscription, the official clients) and streams parsed events.
enum AgentRunner {
    struct Missing: Error { let name: String }

    /// Casual questions run here, so Read/Grep see nothing by default and `@claude+` edits land in a throwaway folder.
    static let scratch: URL = {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchApp/scratch", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    /// A Finder-launched app has a bare PATH; ask a login shell for the real one (once).
    private static let loginPATH: String = {
        let p = Process(), out = Pipe()
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

    static func run(_ route: Route, session: String?) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { cont in
            let work = Task.detached {
                let name = route.backend == .claude ? "claude" : "codex"
                guard let exe = find(name) else { cont.finish(throwing: Missing(name: name)); return }
                let p = Process(), out = Pipe()
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
                    ? AgentStream.claudeArgs(prompt: route.prompt, session: session, work: route.work, folder: route.folder, scratch: scratch.standardizedFileURL.path, mcpConfig: mcp)
                    : AgentStream.codexArgs(prompt: route.prompt, session: session, work: route.work, folder: route.folder, image: route.image)
                p.currentDirectoryURL = cwd
                env["PATH"] = loginPATH
                p.environment = env
                p.standardInput = FileHandle.nullDevice // codex otherwise waits on stdin
                p.standardOutput = out; p.standardError = FileHandle.nullDevice
                do { try p.run() } catch { cont.finish(throwing: error); return }
                cont.onTermination = { _ in if p.isRunning { p.terminate() } }
                var any = false
                do {
                    for try await line in out.fileHandleForReading.bytes.lines {
                        for e in route.backend == .claude ? AgentStream.claudeEvents(line: line) : AgentStream.codexEvents(line: line) {
                            any = true; cont.yield(e)
                        }
                    }
                } catch { cont.finish(throwing: error); return }
                p.waitUntilExit()
                if p.terminationStatus != 0 && !any { cont.finish(throwing: NSError(domain: name, code: Int(p.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: "\(name) exited with code \(p.terminationStatus). Is it logged in?"])); return }
                cont.finish()
            }
            cont.onTermination = { _ in work.cancel() }
        }
    }
}
