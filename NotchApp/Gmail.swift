import Foundation
import CryptoKit
import Network
import AppKit

struct GmailError: LocalizedError { let msg: String; init(_ m: String) { msg = m }; var errorDescription: String? { msg } }

/// Google's "installed app" sign-in: PKCE, with a one-shot listener on 127.0.0.1 to catch the redirect. Read-only mail scope.
enum GoogleOAuth {
    static let scope = "https://www.googleapis.com/auth/gmail.readonly"

    private static func b64url(_ d: some DataProtocol) -> String {
        Data(d).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func verifier() -> String { b64url((0..<48).map { _ in UInt8.random(in: 0...255) }) }
    static func challenge(_ verifier: String) -> String { b64url(Data(SHA256.hash(data: Data(verifier.utf8)))) }

    static func authURL(clientID: String, redirect: String, challenge: String, state: String) -> URL {
        var c = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        c.queryItems = [("client_id", clientID), ("redirect_uri", redirect), ("response_type", "code"), ("scope", scope),
                        ("code_challenge", challenge), ("code_challenge_method", "S256"), ("state", state),
                        ("access_type", "offline"), ("prompt", "consent")].map { URLQueryItem(name: $0.0, value: $0.1) }
        return c.url!
    }

    /// "GET /?code=…&state=… HTTP/1.1" → the pieces. nil for anything that isn't a redirect (favicon requests and the like).
    static func parseCallback(_ head: String) -> (code: String?, state: String?, error: String?)? {
        let parts = head.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET", let c = URLComponents(string: "http://127.0.0.1" + parts[1]) else { return nil }
        let q = Dictionary((c.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        guard q["code"] != nil || q["error"] != nil else { return nil }
        return (q["code"], q["state"], q["error"])
    }

    static func form(_ pairs: [(String, String)]) -> Data {
        let ok = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return Data(pairs.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: ok) ?? "")" }.joined(separator: "&").utf8)
    }
}

/// Accepts the browser's redirect, answers with a small page, hands the request line to whoever is waiting.
final class LoopbackListener: @unchecked Sendable {
    private let listener: NWListener
    private let q = DispatchQueue(label: "notch.oauth")
    private var ready: CheckedContinuation<UInt16, Error>?
    private var waiting: CheckedContinuation<String, Error>?
    private var arrived: Result<String, Error>?

    init() throws {
        let p = NWParameters.tcp
        p.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: p)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { c in
            q.async {
                self.ready = c
                self.listener.stateUpdateHandler = { [weak self] s in self?.state(s) }
                self.listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
                self.listener.start(queue: self.q)
            }
        }
    }

    func nextRequest() async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { c in
                q.async { if let r = self.arrived { self.arrived = nil; c.resume(with: r) } else { self.waiting = c } }
            }
        } onCancel: { close() }
    }

    func close() {
        q.async {
            self.listener.cancel()
            self.deliver(.failure(CancellationError()))
        }
    }

    private func state(_ s: NWListener.State) {
        switch s {
        case .ready: if let r = ready, let p = listener.port { ready = nil; r.resume(returning: p.rawValue) }
        case .failed(let e): if let r = ready { ready = nil; r.resume(throwing: e) }; deliver(.failure(e))
        default: break
        }
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: q)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            let head = data.map { String(decoding: $0, as: UTF8.self) }?.split(separator: "\r\n").first.map(String.init) ?? ""
            let page = "<!doctype html><meta charset=utf-8><title>dex-notch</title><body style=\"background:#000;color:#f2ebde;font:20px Georgia,serif;display:grid;place-items:center;height:100vh;margin:0\"><p>Gmail is connected. You can close this tab.</p>"
            let body = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(page.utf8.count)\r\nConnection: close\r\n\r\n" + page
            conn.send(content: Data(body.utf8), completion: .contentProcessed { _ in conn.cancel() })
            if GoogleOAuth.parseCallback(head) != nil { self?.deliver(.success(head)) }
        }
    }

    private func deliver(_ r: Result<String, Error>) {
        if let w = waiting { waiting = nil; w.resume(with: r) } else if arrived == nil { arrived = r }
    }
}

enum GmailAPI {
    /// Unread inbox mail the category tabs didn't already file as promotions, social or forums. Anything older than two days is not "upcoming".
    static let query = "in:inbox is:unread -category:promotions -category:social -category:forums newer_than:2d"

    static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&amp;", with: "&")
    }

    /// One `messages.get?format=metadata` response → a MailItem.
    static func parse(_ j: [String: Any]) -> MailItem? {
        guard let id = j["id"] as? String, let thread = j["threadId"] as? String else { return nil }
        let headers = (((j["payload"] as? [String: Any])?["headers"]) as? [[String: Any]]) ?? []
        func h(_ n: String) -> String? { headers.first { ($0["name"] as? String)?.lowercased() == n }?["value"] as? String }
        let ms = Double((j["internalDate"] as? String) ?? "") ?? 0
        return MailItem(id: id, threadId: thread, from: h("from") ?? "", subject: h("subject") ?? "(no subject)",
                        snippet: decodeEntities((j["snippet"] as? String) ?? ""), date: Date(timeIntervalSince1970: ms / 1000),
                        labels: (j["labelIds"] as? [String]) ?? [], bulk: h("list-unsubscribe") != nil)
    }
}

/// Talks to Gmail as you, read-only. The refresh token lives in the login keychain; the access token only in memory.
actor GmailClient {
    static let service = "dex-notch.gmail", account = "refresh-token"
    static func isConnected() -> Bool { KeychainStore.get(service: service, account: account) != nil }

    private let cfg: GmailConfig
    private var access: (token: String, expires: Date)?
    init(_ cfg: GmailConfig) { self.cfg = cfg }

    /// Opens the browser, waits for you to approve, stores the refresh token. Throws with a plain sentence when it can't.
    static func connect(_ cfg: GmailConfig) async throws {
        let server = try LoopbackListener()
        let port = try await server.start()
        let redirect = "http://127.0.0.1:\(port)"
        let verifier = GoogleOAuth.verifier(), state = GoogleOAuth.verifier()
        let url = GoogleOAuth.authURL(clientID: cfg.clientID, redirect: redirect, challenge: GoogleOAuth.challenge(verifier), state: state)
        _ = await MainActor.run { NSWorkspace.shared.open(url) }
        let head: String
        do { head = try await timeout(240) { try await server.nextRequest() } } catch { server.close(); throw GmailError("Sign-in didn't finish. Choose Connect Gmail to try again.") }
        server.close()
        guard let cb = GoogleOAuth.parseCallback(head), cb.state == state else { throw GmailError("Google's reply didn't match this sign-in. Try again.") }
        if let e = cb.error { throw GmailError(e == "access_denied" ? "Access was declined in the browser." : "Google said: \(e).") }
        guard let code = cb.code else { throw GmailError("Google didn't send a sign-in code.") }
        let tok = try await token(cfg, [("grant_type", "authorization_code"), ("code", code), ("redirect_uri", redirect), ("code_verifier", verifier)])
        guard let refresh = tok.refresh, KeychainStore.set(token: refresh, service: service, account: account) else {
            throw GmailError("Google didn't return a long-lived sign-in. Remove dex-notch at myaccount.google.com/permissions and connect again.")
        }
    }

    private static func token(_ cfg: GmailConfig, _ extra: [(String, String)]) async throws -> (access: String, expires: Date, refresh: String?) {
        var r = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        r.httpMethod = "POST"; r.timeoutInterval = 20
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.httpBody = GoogleOAuth.form([("client_id", cfg.clientID), ("client_secret", cfg.clientSecret)] + extra)
        let (d, _) = try await URLSession.shared.data(for: r)
        let j = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
        guard let a = j["access_token"] as? String else {
            let why = (j["error"] as? String) ?? "no reply"
            throw GmailError(why == "invalid_grant" ? "Gmail sign-in expired. Choose Connect Gmail again." : why == "invalid_client" ? "Google rejected the client ID or secret." : "Google sign-in failed (\(why)).")
        }
        return (a, Date().addingTimeInterval((j["expires_in"] as? Double) ?? 3000), j["refresh_token"] as? String)
    }

    private func bearer() async throws -> String {
        if let a = access, a.expires > Date().addingTimeInterval(60) { return a.token }
        guard let refresh = KeychainStore.get(service: Self.service, account: Self.account) else { throw GmailError("Gmail isn't connected.") }
        let t = try await Self.token(cfg, [("grant_type", "refresh_token"), ("refresh_token", refresh)])
        access = (t.access, t.expires)
        return t.access
    }

    private func get(_ path: String, _ query: [URLQueryItem]) async throws -> Data {
        var c = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/" + path)!
        c.queryItems = query
        var r = URLRequest(url: c.url!); r.timeoutInterval = 20
        r.setValue("Bearer \(try await bearer())", forHTTPHeaderField: "Authorization")
        let (d, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { access = nil; throw GmailError("Gmail sign-in expired. Choose Connect Gmail again.") }
        if code == 403 || code == 429 { throw GmailError("Gmail is limiting requests right now. Trying again later.") }
        guard code == 200 else { throw GmailError("Gmail returned HTTP \(code).") }
        return d
    }
    private static func obj(_ d: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:] }

    /// Headers and the snippet only. Message bodies are never downloaded.
    func fetchUnread() async throws -> [MailItem] {
        let list = try await get("messages", [URLQueryItem(name: "q", value: GmailAPI.query), URLQueryItem(name: "maxResults", value: "40")])
        let ids = ((Self.obj(list)["messages"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
        return try await withThrowingTaskGroup(of: MailItem?.self) { g in
            for id in ids {
                g.addTask {
                    let m = try await self.get("messages/" + id, [URLQueryItem(name: "format", value: "metadata")]
                        + ["From", "Subject", "List-Unsubscribe"].map { URLQueryItem(name: "metadataHeaders", value: $0) })
                    return GmailAPI.parse(Self.obj(m))
                }
            }
            var out: [MailItem] = []
            for try await m in g { if let m { out.append(m) } }
            return out
        }
    }
}

/// Runs `op`, giving up after `seconds`. The loser is cancelled (cancelling a model run kills its process).
func timeout<T: Sendable>(_ seconds: Double, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { g in
        g.addTask { try await op() }
        g.addTask { try await Task.sleep(for: .seconds(seconds)); throw GmailError("Timed out.") }
        defer { g.cancelAll() }
        return try await g.next()!
    }
}
