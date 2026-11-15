import Foundation
import CryptoKit
import Network
import AppKit

/// The account was connected read-only; replying needs one more permission from Google.
struct ReplyPermissionNeeded: LocalizedError { var errorDescription: String? { "This account can only read mail. Allow replies first." } }

struct GmailError: LocalizedError { let msg: String; init(_ m: String) { msg = m }; var errorDescription: String? { msg } }

/// Google's "installed app" sign-in: PKCE, with a one-shot listener on 127.0.0.1 to catch the redirect. Read-only mail scope.
enum GoogleOAuth {
    static let scope = "https://www.googleapis.com/auth/gmail.readonly"
    /// Drafts and sending. Asked for only when you first reply from an account, not when you connect it.
    static let composeScope = "https://www.googleapis.com/auth/gmail.compose"

    private static func b64url(_ d: some DataProtocol) -> String {
        Data(d).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func verifier() -> String { b64url((0..<48).map { _ in UInt8.random(in: 0...255) }) }
    static func challenge(_ verifier: String) -> String { b64url(Data(SHA256.hash(data: Data(verifier.utf8)))) }

    static func authURL(clientID: String, redirect: String, challenge: String, state: String, replies: Bool = false, loginHint: String? = nil) -> URL {
        var c = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        var q = [("client_id", clientID), ("redirect_uri", redirect), ("response_type", "code"), ("scope", replies ? scope + " " + composeScope : scope),
                 ("code_challenge", challenge), ("code_challenge_method", "S256"), ("state", state),
                 ("access_type", "offline"), ("include_granted_scopes", "true"), ("prompt", "select_account consent")]
        if let h = loginHint, !h.isEmpty { q.append(("login_hint", h)) }       // upgrading an account: open Google already on that account
        c.queryItems = q.map { URLQueryItem(name: $0.0, value: $0.1) }
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
            let page = "<!doctype html><meta charset=utf-8><title>Dex Notch</title><body style=\"background:#000;color:#f2ebde;font:20px Georgia,serif;display:grid;place-items:center;height:100vh;margin:0\"><p>Gmail is connected. You can close this tab.</p>"
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
    /// Unread inbox mail the category tabs didn't already file as promotions, social or forums. Anything older than three days is not "upcoming".
    static let query = "in:inbox is:unread -category:promotions -category:social -category:forums newer_than:3d"

    /// A non-200 reply → what to tell the user, and whether waiting and retrying can help. Uses Google's own reason rather than guessing.
    static func explain(code: Int, body: Data) -> (message: String, retry: Bool) {
        let e = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["error"] as? [String: Any]
        let reason = ((e?["errors"] as? [[String: Any]])?.first?["reason"] as? String) ?? (e?["status"] as? String) ?? ""
        let said = (e?["message"] as? String).map { String($0.prefix(140)) }
        switch (code, reason) {
        case (401, _): return ("Gmail sign-in expired. Add the account again in Settings.", false)
        case (429, _), (_, "rateLimitExceeded"), (_, "userRateLimitExceeded"), (_, "RESOURCE_EXHAUSTED"): return ("Gmail is limiting requests right now. It will try again later.", true)
        case (_, "accessNotConfigured"), (_, "SERVICE_DISABLED"): return ("The Gmail API isn't enabled for this Google project. Turn it on in the Google Cloud console.", false)
        case (_, "insufficientPermissions"), (_, "PERMISSION_DENIED"): return ("Gmail didn't grant mail access. Add the account again and approve read-only access.", false)
        case (500...599, _): return ("Gmail had a problem on its side. It will try again later.", true)
        default: return (said.map { "Gmail said: \($0)" } ?? "Gmail returned HTTP \(code).", false)
        }
    }

    /// A 403 that means "this sign-in wasn't given that permission", as opposed to a limit or an outage.
    static func lacksPermission(_ body: Data) -> Bool {
        let s = String(decoding: body, as: UTF8.self).lowercased()
        return s.contains("insufficient") || s.contains("scope_insufficient") || s.contains("insufficientpermissions")
    }

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

/// Talks to one Gmail account, read-only. Its refresh token lives in the login keychain under the account's address; the access token only in memory.
actor GmailClient {
    static let service = "dex-notch.gmail"
    static let legacyAccount = "refresh-token"          // before several accounts were supported there was a single token under this name

    private let cfg: GmailConfig
    private let email: String
    private var access: (token: String, expires: Date)?
    init(_ cfg: GmailConfig, email: String) { self.cfg = cfg; self.email = email }

    static func forget(_ email: String) { KeychainStore.delete(service: service, account: email) }

    /// Opens the browser, waits for you to approve, and stores the refresh token under the address Google says you signed in as.
    /// Returns that address. Signing in again with the same address just refreshes its token.
    static func connect(_ cfg: GmailConfig, replies: Bool = false, loginHint: String? = nil) async throws -> (email: String, canReply: Bool) {
        let server = try LoopbackListener()
        let port = try await server.start()
        let redirect = "http://127.0.0.1:\(port)"
        let verifier = GoogleOAuth.verifier(), state = GoogleOAuth.verifier()
        let url = GoogleOAuth.authURL(clientID: cfg.clientID, redirect: redirect, challenge: GoogleOAuth.challenge(verifier), state: state, replies: replies, loginHint: loginHint)
        _ = await MainActor.run { NSWorkspace.shared.open(url) }
        let head: String
        do { head = try await timeout(240) { try await server.nextRequest() } } catch { server.close(); throw GmailError("Sign-in didn't finish. Choose Add account to try again.") }
        server.close()
        guard let cb = GoogleOAuth.parseCallback(head), cb.state == state else { throw GmailError("Google's reply didn't match this sign-in. Try again.") }
        if let e = cb.error { throw GmailError(e == "access_denied" ? "Access was declined in the browser." : "Google said: \(e).") }
        guard let code = cb.code else { throw GmailError("Google didn't send a sign-in code.") }
        let tok = try await token(cfg, [("grant_type", "authorization_code"), ("code", code), ("redirect_uri", redirect), ("code_verifier", verifier)])
        guard let refresh = tok.refresh else { throw GmailError("Google didn't return a long-lived sign-in. Remove Dex Notch at myaccount.google.com/permissions and add the account again.") }
        let email = try await profileEmail(access: tok.access)
        guard KeychainStore.set(token: refresh, service: service, account: email) else { throw GmailError("Couldn't save the sign-in to your Keychain.") }
        return (email, tok.scope.contains("gmail.compose"))        // what Google actually granted, not what we asked for
    }

    /// One-time move of the old single-account token to the per-address layout. nil if there was nothing to move or it no longer works.
    static func migrateLegacy(_ cfg: GmailConfig) async -> String? {
        guard let old = KeychainStore.get(service: service, account: legacyAccount),
              let t = try? await token(cfg, [("grant_type", "refresh_token"), ("refresh_token", old)]),
              let email = try? await profileEmail(access: t.access),
              KeychainStore.set(token: old, service: service, account: email) else { return nil }
        KeychainStore.delete(service: service, account: legacyAccount)
        return email
    }

    private static func profileEmail(access: String) async throws -> String {
        var r = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/profile")!); r.timeoutInterval = 20
        r.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        let (d, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw GmailError(GmailAPI.explain(code: code, body: d).message) }
        guard let e = (try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["emailAddress"] as? String, !e.isEmpty else { throw GmailError("Gmail didn't say which account this is.") }
        return e.lowercased()
    }

    private static func token(_ cfg: GmailConfig, _ extra: [(String, String)]) async throws -> (access: String, expires: Date, refresh: String?, scope: String) {
        var r = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        r.httpMethod = "POST"; r.timeoutInterval = 20
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.httpBody = GoogleOAuth.form([("client_id", cfg.clientID), ("client_secret", cfg.clientSecret)] + extra)
        let (d, _) = try await URLSession.shared.data(for: r)
        let j = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
        guard let a = j["access_token"] as? String else {
            let why = (j["error"] as? String) ?? "no reply"
            throw GmailError(why == "invalid_grant" ? "Gmail sign-in expired. Add the account again in Settings." : why == "invalid_client" ? "Google rejected the client ID or secret." : "Google sign-in failed (\(why)).")
        }
        return (a, Date().addingTimeInterval((j["expires_in"] as? Double) ?? 3000), j["refresh_token"] as? String, (j["scope"] as? String) ?? "")
    }

    private func bearer() async throws -> String {
        if let a = access, a.expires > Date().addingTimeInterval(60) { return a.token }
        guard let refresh = KeychainStore.get(service: Self.service, account: email) else { throw GmailError("\(email) isn't connected. Add it again in Settings.") }
        let t = try await Self.token(cfg, [("grant_type", "refresh_token"), ("refresh_token", refresh)])
        access = (t.access, t.expires)
        return t.access
    }

    /// One request, retried with a growing pause when Gmail says slow down.
    private func get(_ path: String, _ query: [URLQueryItem]) async throws -> Data { try await request("GET", path, query, nil) }

    /// One request, retried with a growing pause when Gmail says slow down. A write that the account has no permission for says so by name.
    private func request(_ method: String, _ path: String, _ query: [URLQueryItem], _ body: Data?) async throws -> Data {
        var c = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/" + path)!
        if !query.isEmpty { c.queryItems = query }
        for attempt in 0..<4 {
            var r = URLRequest(url: c.url!); r.timeoutInterval = 30; r.httpMethod = method
            r.setValue("Bearer \(try await bearer())", forHTTPHeaderField: "Authorization")
            if let body { r.httpBody = body; r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            let (d, resp) = try await URLSession.shared.data(for: r)
            let http = resp as? HTTPURLResponse, code = http?.statusCode ?? 0
            if (200..<300).contains(code) { return d }
            if code == 401 { access = nil }
            if method != "GET", code == 403, GmailAPI.lacksPermission(d) { throw ReplyPermissionNeeded() }
            let why = GmailAPI.explain(code: code, body: d)
            guard why.retry, attempt < 3, method == "GET" else { throw GmailError(why.message) }      // a send is never repeated on its own: it could go out twice
            let wait = http?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? pow(2, Double(attempt)) * 1.5
            try await Task.sleep(for: .seconds(min(wait, 20)))
        }
        throw GmailError("Gmail kept refusing. It will try again later.")
    }

    // MARK: replying (only when you ask)

    /// One whole email, read because you want to reply to it or ask about it.
    func fullMessage(id: String) async throws -> MailContext {
        let d = try await get("messages/" + id, [URLQueryItem(name: "format", value: "full")])
        guard let c = MailReply.parse(Self.obj(d), account: email) else { throw GmailError("Couldn't read that email.") }
        return c
    }

    /// Saves the reply as a draft in the thread, for you to finish in Gmail. Returns the draft's id.
    func createDraft(raw: String, threadId: String) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: ["message": ["raw": raw, "threadId": threadId]])
        let d = try await request("POST", "drafts", [], body)
        return (Self.obj(d)["id"] as? String) ?? ""
    }

    /// Sends the reply. Only ever called after you pressed Send and the undo time ran out.
    func send(raw: String, threadId: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["raw": raw, "threadId": threadId])
        _ = try await request("POST", "messages/send", [], body)
    }

    private static func obj(_ d: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:] }

    /// Unread mail we haven't judged yet: list the ids (cheap), drop the ones already seen, then read headers and the snippet for at most
    /// `limit` of them, four at a time. Message bodies are never downloaded.
    func fetchUnread(skipping seen: Set<String>, limit: Int = Triage.batch) async throws -> [MailItem] {
        let list = try await get("messages", [URLQueryItem(name: "q", value: GmailAPI.query), URLQueryItem(name: "maxResults", value: "60")])
        let me = email
        let ids = ((Self.obj(list)["messages"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }.filter { !seen.contains(me + "|" + $0) }.prefix(limit)
        return try await withThrowingTaskGroup(of: MailItem?.self) { g in
            var queue = Array(ids).makeIterator(), out: [MailItem] = []
            func add() { if let id = queue.next() { g.addTask {
                let m = try await self.get("messages/" + id, [URLQueryItem(name: "format", value: "metadata")]
                    + ["From", "Subject", "List-Unsubscribe"].map { URLQueryItem(name: "metadataHeaders", value: $0) })
                guard var item = GmailAPI.parse(Self.obj(m)) else { return nil }
                item.account = me; item.id = me + "|" + item.id          // ids are only unique within an account
                return item
            } } }
            for _ in 0..<4 { add() }                                   // four in flight, a new one starts as each finishes
            while let m = try await g.next() { if let m { out.append(m) }; add() }
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
