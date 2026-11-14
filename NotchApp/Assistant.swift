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

    var isOpen = false
    var link: Link = .connecting
    var draft = ""
    var turns: [Turn] = []
    var waiting = false     // sent, no token yet
    var streaming = false   // tokens arriving
    var error: String?

    /// Called whenever isOpen flips so the window can take/release key focus.
    var onOpenChange: ((Bool) -> Void)?

    private var task: Task<Void, Never>?
    private var token: String?

    var question: String? { turns.last(where: { $0.role == "user" })?.text }
    var answer: String { turns.last(where: { $0.role == "assistant" })?.text ?? "" }
    var busy: Bool { waiting || streaming }

    // MARK: open / close

    func toggle() { isOpen ? close() : open() }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        onOpenChange?(true)
        if link != .ready { connect() }
    }

    func close() {
        guard isOpen else { return }
        task?.cancel()
        isOpen = false
        onOpenChange?(false)
        // clear after the collapse animation so the content doesn't snap away mid-close
        Task { try? await Task.sleep(for: .milliseconds(450)); if !isOpen { reset() } }
    }

    private func reset() { turns = []; draft = ""; error = nil; waiting = false; streaming = false }

    // MARK: ask

    func send() {
        let q = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !busy else { return }
        draft = ""; error = nil
        turns.append(Turn(role: "user", text: q))
        turns.append(Turn(role: "assistant", text: ""))
        waiting = true

        let messages = [["role": "system", "content": Self.system]]
            + turns.dropLast().map { ["role": $0.role, "content": $0.text] }

        task = Task {
            do {
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
                    if let t = (j["message"] as? [String: Any])?["content"] as? String, !t.isEmpty {
                        waiting = false; streaming = true
                        turns[turns.count - 1].text += t
                    }
                    if j["done"] as? Bool == true { break }
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

    private func finish() {
        waiting = false; streaming = false
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
