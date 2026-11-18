import Foundation

/// What the server said when asked "is this Mac still linked to a live account?"
enum ServerAnswer: Equatable {
    case confirmed(email: String)
    case rejected          // the server answered, and this Mac is no longer linked (removed from the account, or the account was deleted)
    case unreachable       // no answer: offline, server down, or an error that says nothing about the account
}

enum GateVerdict: Equatable { case open, needsAccount, locked }

enum LinkPoll: Equatable { case pending, expired, approved(token: String, email: String) }

struct LinkStart: Equatable { let code: String; let secret: String; let url: URL; let expiresIn: Int }

/// Dex Notch runs only while this Mac is linked to a Dex account that the server has confirmed.
enum Gate {
    /// How long a confirmation keeps the app running when the server can't be reached (a laptop on a plane).
    static let grace: TimeInterval = 7 * 86_400

    static func decide(hasToken: Bool, answer: ServerAnswer, lastConfirmed: Date?, now: Date) -> GateVerdict {
        guard hasToken else { return .needsAccount }
        switch answer {
        case .confirmed: return .open
        case .rejected: return .needsAccount
        case .unreachable:
            // a clock set back must not stretch the grace period
            if let t = lastConfirmed, t <= now.addingTimeInterval(60), now.timeIntervalSince(t) < grace { return .open }
            return .locked
        }
    }
}

/// The few calls the app makes to the hosted service. Everything is over HTTPS to the one host in settings.json.
enum HostedAPI {
    static let confirmedKey = "hostedConfirmedAt", emailKey = "hostedEmail"

    /// Always https. A Debug build also lets a server on this Mac (localhost or 127.0.0.1) use plain http, so the demo server needs no certificate. Release builds never do.
    static func scheme(for host: String) -> String {
        #if DEBUG
        let name = host.split(separator: ":").first.map(String.init) ?? host
        if name == "localhost" || name == "127.0.0.1" { return "http" }
        #endif
        return "https"
    }

    static func base(_ host: String) -> URL? { Settings.normalizeHost(host).flatMap { URL(string: "\(scheme(for: $0))://\($0)") } }

    /// The link page must be on the same host the app asked: a reply can't send the browser, or the person, anywhere else.
    static func parseStart(_ d: Data, host: String) -> LinkStart? {
        guard let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let code = o["code"] as? String, let secret = o["secret"] as? String, let s = o["url"] as? String, let url = URL(string: s),
              code.range(of: #"^[A-Z2-9]{4}-[A-Z2-9]{4}\z"#, options: .regularExpression) != nil, !secret.isEmpty,
              url.scheme == scheme(for: host), let b = base(host), url.host == b.host, url.path == "/link" else { return nil }
        return LinkStart(code: code, secret: secret, url: url, expiresIn: (o["expires_in"] as? Int) ?? 600)
    }

    static func parsePoll(_ d: Data) -> LinkPoll? {
        guard let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], let st = o["status"] as? String else { return nil }
        switch st {
        case "pending": return .pending
        case "expired": return .expired
        case "approved":
            guard let t = o["token"] as? String, HostedAccount.isValidToken(t), let e = o["email"] as? String, !e.isEmpty else { return nil }
            return .approved(token: t, email: e)
        default: return nil
        }
    }

    static func parseMe(status: Int, _ d: Data) -> ServerAnswer {
        if status == 401 { return .rejected }
        guard status == 200, let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], let e = o["email"] as? String, !e.isEmpty else { return .unreachable }
        return .confirmed(email: e)
    }

    private static func post(_ url: URL, _ body: [String: String]) async throws -> Data {
        var r = URLRequest(url: url, timeoutInterval: 15)
        r.httpMethod = "POST"; r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (d, resp) = try await URLSession.shared.data(for: r)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return d
    }

    static func startLink(host: String, name: String) async throws -> LinkStart {
        guard let b = base(host) else { throw URLError(.badURL) }
        guard let s = parseStart(try await post(b.appendingPathComponent("v1/link/start"), ["name": name]), host: host) else { throw URLError(.cannotParseResponse) }
        return s
    }

    static func poll(host: String, secret: String) async throws -> LinkPoll {
        guard let b = base(host) else { throw URLError(.badURL) }
        guard let p = parsePoll(try await post(b.appendingPathComponent("v1/link/poll"), ["secret": secret])) else { throw URLError(.cannotParseResponse) }
        return p
    }

    /// Which of Claude and ChatGPT hold a live authorization for this account (nil when the server can't be asked).
    static func assistants(host: String, token: String) async -> (claude: Bool, chatgpt: Bool, vault: Bool?, uploaded: Bool?, used: Bool?)? {
        guard let b = base(host) else { return nil }
        var r = URLRequest(url: b.appendingPathComponent("v1/me"), timeoutInterval: 10)
        r.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        guard let (d, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return ConnectionLogic.parseAssistants(d)
    }

    static func me(host: String, token: String) async -> ServerAnswer {
        guard let b = base(host) else { return .unreachable }
        var r = URLRequest(url: b.appendingPathComponent("v1/me"), timeoutInterval: 10)
        r.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        guard let (d, resp) = try? await URLSession.shared.data(for: r), let code = (resp as? HTTPURLResponse)?.statusCode else { return .unreachable }
        return parseMe(status: code, d)
    }
}

/// The text a tester pastes into a bug report. Facts about setup only: no email address, token, mail account name, folder path or conversation text.
enum Diagnostics {
    static let issueURL = URL(string: "https://github.com/Dextron04/dex-notch/issues/new")!
    static let guideURL = URL(string: "https://github.com/Dextron04/dex-notch/blob/master/docs/install.md")!

    static func report(version: String, macOS: String, host: String?, uploads: Bool, lastConfirmed: Date?, phoneAlerts: Bool, fullDiskAccess: Bool,
                       macAlerts: Bool, mailAccounts: Int, now: Date = Date()) -> String {
        let seen = lastConfirmed.map { "\(max(0, Int(now.timeIntervalSince($0) / 60))) min ago" } ?? "never"
        return """
        Dex Notch \(version) on macOS \(macOS)
        Server: \(host ?? "not linked") (last confirmed \(seen))
        Uploading conversations: \(uploads ? "yes" : "no")
        iPhone notifications: \(phoneAlerts ? "on" : "off"), Full Disk Access: \(fullDiskAccess ? "granted" : "missing")
        Judging this Mac's notifications: \(macAlerts ? "on" : "off")
        Mail accounts: \(mailAccounts)
        """
    }
}
