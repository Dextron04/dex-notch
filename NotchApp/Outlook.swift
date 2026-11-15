import Foundation
import AppKit

/// What the rest of the app needs from a mail account, whoever hosts it. Gmail and Outlook both answer these four things.
protocol MailProvider: Sendable {
    func fetchUnread(skipping seen: Set<String>, limit: Int) async throws -> [MailItem]
    func fullMessage(id: String) async throws -> MailContext
    func send(_ ctx: MailContext, body: String) async throws
    func saveDraft(_ ctx: MailContext, body: String) async throws
}

extension GmailClient: MailProvider {
    func send(_ ctx: MailContext, body: String) async throws {
        guard let raw = MailReply.raw(ctx, body: body) else { throw GmailError("This sender has no address to reply to.") }
        try await send(raw: raw, threadId: ctx.threadId)
    }
    func saveDraft(_ ctx: MailContext, body: String) async throws {
        guard let raw = MailReply.raw(ctx, body: body) else { throw GmailError("This sender has no address to reply to.") }
        _ = try await createDraft(raw: raw, threadId: ctx.threadId)
    }
}

/// Microsoft's sign-in for Outlook.com, Hotmail and Microsoft 365: PKCE through the same one-shot loopback listener as Google.
/// A desktop app can't keep a secret, so there is only a client (application) ID. Microsoft treats `http://localhost:<any port>` as one redirect.
enum MicrosoftOAuth {
    static let base = "https://login.microsoftonline.com/common/oauth2/v2.0"
    static let readScope = "offline_access User.Read Mail.Read"
    /// Drafts and sending. Asked for when you connect (unless you turned replies off) or the first time you reply.
    static let replyScope = "Mail.ReadWrite Mail.Send"

    static func authURL(clientID: String, redirect: String, challenge: String, state: String, replies: Bool, loginHint: String? = nil) -> URL {
        var c = URLComponents(string: base + "/authorize")!
        var q = [("client_id", clientID), ("response_type", "code"), ("redirect_uri", redirect), ("response_mode", "query"),
                 ("scope", replies ? readScope + " " + replyScope : readScope), ("code_challenge", challenge), ("code_challenge_method", "S256"),
                 ("state", state), ("prompt", "select_account")]
        if let h = loginHint, !h.isEmpty { q.append(("login_hint", h)) }
        c.queryItems = q.map { URLQueryItem(name: $0.0, value: $0.1) }
        return c.url!
    }
}

/// Everything about Outlook mail that needs no network, so it can be tested.
enum OutlookAPI {
    static let graph = "https://graph.microsoft.com/v1.0"
    static let fields = "id,conversationId,from,subject,bodyPreview,receivedDateTime,inferenceClassification,webLink,internetMessageHeaders"

    /// Unread inbox mail from the last three days, newest first. (Graph wants the sorted field first in the filter.)
    static func listQuery(since: Date) -> [URLQueryItem] {
        [URLQueryItem(name: "$filter", value: "receivedDateTime ge \(ISO8601DateFormatter().string(from: since)) and isRead eq false"),
         URLQueryItem(name: "$orderby", value: "receivedDateTime desc"), URLQueryItem(name: "$top", value: "40"), URLQueryItem(name: "$select", value: fields)]
    }

    static func date(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        return f.date(from: s) ?? { f.formatOptions.insert(.withFractionalSeconds); return f.date(from: s) }()
    }

    /// {"emailAddress": {"name": "Priya", "address": "p@x.com"}} → "Priya <p@x.com>"
    static func person(_ j: Any?) -> String {
        guard let e = (j as? [String: Any])?["emailAddress"] as? [String: Any], let a = e["address"] as? String, !a.isEmpty else { return "" }
        let n = ((e["name"] as? String) ?? "").replacingOccurrences(of: "<", with: "").replacingOccurrences(of: ">", with: "").trimmingCharacters(in: .whitespaces)
        return n.isEmpty || n == a ? a : "\(n) <\(a)>"
    }

    private static func header(_ j: [String: Any], _ name: String) -> String? {
        ((j["internetMessageHeaders"] as? [[String: Any]]) ?? []).first { ($0["name"] as? String)?.lowercased() == name.lowercased() }?["value"] as? String
    }

    /// One message from the inbox list → a MailItem. Outlook's own "Other" tab (what it files as bulk mail) plays the part of Gmail's Promotions tab.
    static func parse(_ j: [String: Any]) -> MailItem? {
        guard let id = j["id"] as? String, let thread = j["conversationId"] as? String else { return nil }
        var labels = ["INBOX", "UNREAD"]
        if (j["inferenceClassification"] as? String)?.lowercased() == "other" { labels.append("CATEGORY_PROMOTIONS") }
        let subject = (j["subject"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "(no subject)"
        var m = MailItem(id: id, threadId: thread, from: person(j["from"]), subject: subject, snippet: (j["bodyPreview"] as? String) ?? "",
                         date: date(j["receivedDateTime"] as? String) ?? Date(), labels: labels, bulk: header(j, "list-unsubscribe") != nil)
        m.provider = "outlook"; m.link = (j["webLink"] as? String) ?? ""
        return m
    }

    /// One whole message, read because you want to reply to it or ask about it.
    static func context(_ j: [String: Any], account: String) -> MailContext? {
        guard let id = j["id"] as? String else { return nil }
        let body = j["body"] as? [String: Any]
        let raw = (body?["content"] as? String) ?? ""
        let text = ((body?["contentType"] as? String)?.lowercased() == "html") ? MailReply.stripHTML(raw) : raw
        return MailContext(account: account, id: id, threadId: (j["conversationId"] as? String) ?? id, from: person(j["from"]),
                           replyTo: person(((j["replyTo"] as? [Any]) ?? []).first), subject: (j["subject"] as? String) ?? "",
                           messageID: (j["internetMessageId"] as? String) ?? "", references: header(j, "references") ?? "",
                           date: date(j["receivedDateTime"] as? String),
                           body: MailReply.clip(text.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines), MailReply.bodyLimit))
    }

    /// The reply text as Graph wants it: it is placed above the quoted original as HTML, so nothing the AI wrote can be read as markup.
    static func comment(_ body: String) -> String {
        body.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "<br>")
    }

    /// A message id as one URL path piece.
    static func pathID(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~=")) ?? id
    }

    private static func errorInfo(_ body: Data) -> (code: String, message: String) {
        let e = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["error"] as? [String: Any]
        return ((e?["code"] as? String) ?? "", (e?["message"] as? String).map { String($0.prefix(140)) } ?? "")
    }

    /// A non-2xx reply → what to tell the user, and whether waiting and retrying can help.
    static func explain(code: Int, body: Data) -> (message: String, retry: Bool) {
        let e = errorInfo(body)
        switch code {
        case 401: return ("Outlook sign-in expired. Add the account again in Settings.", false)
        case 429, 503, 504, 500...599: return ("Outlook is limiting requests or having a problem. It will try again later.", true)
        default: return (e.message.isEmpty ? "Outlook returned HTTP \(code)." : "Outlook said: \(e.message)", false)
        }
    }

    /// A 403 that means "this sign-in wasn't given that permission".
    static func lacksPermission(_ body: Data) -> Bool { ["ErrorAccessDenied", "ErrorInsufficientPermissions"].contains(errorInfo(body).code) }
}

/// Talks to one Outlook or Microsoft 365 mailbox. Its refresh token lives in the login keychain under the account's address; the access token only in memory.
actor OutlookClient: MailProvider {
    static let service = "dex-notch.outlook"

    private let clientID: String
    private let email: String
    private var access: (token: String, expires: Date)?
    init(clientID: String, email: String) { self.clientID = clientID; self.email = email }

    static func forget(_ email: String) { KeychainStore.delete(service: service, account: email) }

    /// Opens the browser, waits for you to approve, and stores the refresh token under the address Microsoft says you signed in as.
    static func connect(clientID: String, replies: Bool, loginHint: String? = nil) async throws -> (email: String, canReply: Bool) {
        let server = try LoopbackListener()
        let port = try await server.start()
        let redirect = "http://localhost:\(port)"
        let verifier = GoogleOAuth.verifier(), state = GoogleOAuth.verifier()
        let url = MicrosoftOAuth.authURL(clientID: clientID, redirect: redirect, challenge: GoogleOAuth.challenge(verifier), state: state, replies: replies, loginHint: loginHint)
        _ = await MainActor.run { NSWorkspace.shared.open(url) }
        let head: String
        do { head = try await timeout(240) { try await server.nextRequest() } } catch { server.close(); throw GmailError("Sign-in didn't finish. Choose Connect Outlook to try again.") }
        server.close()
        guard let cb = GoogleOAuth.parseCallback(head), cb.state == state else { throw GmailError("Microsoft's reply didn't match this sign-in. Try again.") }
        if let e = cb.error { throw GmailError(e == "access_denied" ? "Access was declined in the browser." : "Microsoft said: \(e).") }
        guard let code = cb.code else { throw GmailError("Microsoft didn't send a sign-in code.") }
        let tok = try await token(clientID, [("grant_type", "authorization_code"), ("code", code), ("redirect_uri", redirect), ("code_verifier", verifier)])
        guard let refresh = tok.refresh else { throw GmailError("Microsoft didn't return a long-lived sign-in. Try again.") }
        let email = try await profileEmail(access: tok.access)
        guard KeychainStore.set(token: refresh, service: service, account: email) else { throw GmailError("Couldn't save the sign-in to your Keychain.") }
        return (email, tok.scope.lowercased().contains("mail.send"))        // what Microsoft actually granted, not what we asked for
    }

    private static func profileEmail(access: String) async throws -> String {
        var r = URLRequest(url: URL(string: OutlookAPI.graph + "/me?$select=mail,userPrincipalName")!); r.timeoutInterval = 20
        r.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        let (d, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw GmailError(OutlookAPI.explain(code: code, body: d).message) }
        let j = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
        guard let e = ((j["mail"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (j["userPrincipalName"] as? String)), e.contains("@") else { throw GmailError("Microsoft didn't say which account this is.") }
        return e.lowercased()
    }

    private static func token(_ clientID: String, _ extra: [(String, String)]) async throws -> (access: String, expires: Date, refresh: String?, scope: String) {
        var r = URLRequest(url: URL(string: MicrosoftOAuth.base + "/token")!)
        r.httpMethod = "POST"; r.timeoutInterval = 20
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.httpBody = GoogleOAuth.form([("client_id", clientID)] + extra)
        let (d, _) = try await URLSession.shared.data(for: r)
        let j = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
        guard let a = j["access_token"] as? String else {
            let why = (j["error"] as? String) ?? "no reply"
            throw GmailError(why == "invalid_grant" ? "Outlook sign-in expired. Add the account again in Settings."
                : why == "invalid_client" || why == "unauthorized_client" ? "Microsoft doesn't recognise this application ID, or it isn't set up as a desktop app." : "Microsoft sign-in failed (\(why)).")
        }
        return (a, Date().addingTimeInterval((j["expires_in"] as? Double) ?? 3000), j["refresh_token"] as? String, (j["scope"] as? String) ?? "")
    }

    private func bearer() async throws -> String {
        if let a = access, a.expires > Date().addingTimeInterval(60) { return a.token }
        guard let refresh = KeychainStore.get(service: Self.service, account: email) else { throw GmailError("\(email) isn't connected. Add it again in Settings.") }
        let t = try await Self.token(clientID, [("grant_type", "refresh_token"), ("refresh_token", refresh)])
        if let next = t.refresh, next != refresh { _ = KeychainStore.set(token: next, service: Self.service, account: email) }      // Microsoft hands out a fresh refresh token each time
        access = (t.access, t.expires)
        return t.access
    }

    /// One request, retried with a growing pause when Outlook says slow down (reads only: a send is never repeated on its own).
    private func request(_ method: String, _ path: String, _ query: [URLQueryItem] = [], body: Data? = nil, textBody: Bool = false) async throws -> Data {
        var c = URLComponents(string: OutlookAPI.graph + "/me/" + path)!
        if !query.isEmpty { c.queryItems = query }
        for attempt in 0..<4 {
            var r = URLRequest(url: c.url!); r.timeoutInterval = 30; r.httpMethod = method
            r.setValue("Bearer \(try await bearer())", forHTTPHeaderField: "Authorization")
            if textBody { r.setValue("outlook.body-content-type=\"text\"", forHTTPHeaderField: "Prefer") }
            if let body { r.httpBody = body; r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            let (d, resp) = try await URLSession.shared.data(for: r)
            let http = resp as? HTTPURLResponse, code = http?.statusCode ?? 0
            if (200..<300).contains(code) { return d }
            if code == 401 { access = nil }
            if method != "GET", code == 403, OutlookAPI.lacksPermission(d) { throw ReplyPermissionNeeded() }
            let why = OutlookAPI.explain(code: code, body: d)
            guard why.retry, attempt < 3, method == "GET" else { throw GmailError(why.message) }
            let wait = http?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? pow(2, Double(attempt)) * 1.5
            try await Task.sleep(for: .seconds(min(wait, 20)))
        }
        throw GmailError("Outlook kept refusing. It will try again later.")
    }

    private static func obj(_ d: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:] }

    /// Unread inbox mail we haven't judged yet. One list request carries the headers and a short preview; bodies are never downloaded.
    func fetchUnread(skipping seen: Set<String>, limit: Int) async throws -> [MailItem] {
        let d = try await request("GET", "mailFolders/inbox/messages", OutlookAPI.listQuery(since: Date().addingTimeInterval(-3 * 86400)))
        let me = email
        return ((Self.obj(d)["value"] as? [[String: Any]]) ?? []).compactMap { OutlookAPI.parse($0) }.compactMap { m -> MailItem? in
            var item = m; item.account = me; item.id = me + "|" + m.id          // ids are only unique within an account
            return seen.contains(item.id) ? nil : item
        }.prefix(limit).map { $0 }
    }

    func fullMessage(id: String) async throws -> MailContext {
        let d = try await request("GET", "messages/" + OutlookAPI.pathID(id),
                                  [URLQueryItem(name: "$select", value: "id,conversationId,from,replyTo,subject,body,receivedDateTime,internetMessageId,internetMessageHeaders")], textBody: true)
        guard let c = OutlookAPI.context(Self.obj(d), account: email) else { throw GmailError("Couldn't read that email.") }
        return c
    }

    /// Sends the reply from the original message, so Outlook threads it and quotes the original itself. Only ever called after Send and the undo time.
    func send(_ ctx: MailContext, body: String) async throws {
        _ = try await request("POST", "messages/" + OutlookAPI.pathID(ctx.id) + "/reply", body: try JSONSerialization.data(withJSONObject: ["comment": OutlookAPI.comment(body)]))
    }

    /// Saves the reply in Drafts, in the same conversation, to finish in Outlook.
    func saveDraft(_ ctx: MailContext, body: String) async throws {
        _ = try await request("POST", "messages/" + OutlookAPI.pathID(ctx.id) + "/createReply", body: try JSONSerialization.data(withJSONObject: ["comment": OutlookAPI.comment(body)]))
    }
}
