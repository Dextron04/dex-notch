import Foundation

/// A reminder someone set for you from another assistant ("remind me to call mum at 9"). It arrives as a small file in the vault's Reminders folder.
struct Reminder: Equatable, Sendable {
    let id: String
    let text: String
    let source: String      // chatgpt | claude-web | other-ai
    let due: Date
    var file: URL? = nil    // where it lives, so a finished one can be cleaned up

    var sourceName: String { source == "chatgpt" ? "ChatGPT" : source == "claude-web" ? "Claude" : "an assistant" }
}

enum Reminders {
    /// Reminders further overdue than this were missed while the app was off for days; they are marked done without a card.
    static let staleAfter: TimeInterval = 86_400
    static let snooze: TimeInterval = 600
    /// A reminder you ignore comes back, but only this many times in all; after that it is left alone rather than nagging for ever.
    static let maxShows = 3

    static func load(vault: URL) -> [Reminder] {
        let dir = vault.appendingPathComponent("Reminders")
        return ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "md" && !$0.lastPathComponent.contains(".sync-conflict-") }
            .compactMap { url in
                let h = VaultReader.header(url)
                guard let id = h["id"] as? String, let text = h["text"] as? String, !text.isEmpty,
                      let due = (h["due"] as? String).flatMap(VaultReader.parseDate) else { return nil }
                return Reminder(id: id, text: text, source: (h["source"] as? String) ?? "", due: due, file: url)
            }
            .sorted { $0.due < $1.due }
    }

    /// Reminders whose time has come and that haven't been shown (`done`), honouring a snooze. Oldest first.
    static func due(_ all: [Reminder], done: [String], snoozed: [String: Date], now: Date) -> [Reminder] {
        let finished = Set(done)
        return all.filter { !finished.contains($0.id) && (snoozed[$0.id] ?? $0.due) <= now }
    }

    /// Reminders whose card is over: shown already (in `done`), not snoozed back for another go, and not on screen or queued right now.
    /// Their files can be deleted; `done` keeps the id, so a copy that arrives again later is never shown.
    static func finished(_ all: [Reminder], done: [String], snoozed: [String: Date], onScreen: Set<String>) -> [Reminder] {
        let d = Set(done)
        return all.filter { d.contains($0.id) && snoozed[$0.id] == nil && !onScreen.contains($0.id) }
    }
    static func remove(_ rs: [Reminder]) { for r in rs { if let f = r.file { try? FileManager.default.removeItem(at: f) } } }

    static let doneLimit = 2000
    /// Keeps `done` to `limit` ids by dropping the oldest, but never an id whose file is still on disk: forgetting it would show it again.
    static func trimmed(_ done: [String], present: Set<String>, limit: Int = doneLimit) -> [String] {
        var excess = done.count - limit
        guard excess > 0 else { return done }
        return done.filter { id in if excess > 0, !present.contains(id) { excess -= 1; return false }; return true }
    }
}

/// Mac notifications waiting for the AI judge, kept on disk so a quit before the model answers doesn't lose them.
enum MacBuffer {
    static let maxAge: TimeInterval = 3600

    /// Drops what is more than an hour old and keeps the newest `Triage.batch`.
    static func prune(_ items: [MailItem], now: Date) -> [MailItem] {
        Array(items.filter { now.timeIntervalSince($0.date) <= maxAge }.suffix(Triage.batch))
    }
    static var defaultURL: URL {
        if let p = ProcessInfo.processInfo.environment["NOTCH_MACBUFFER"], !p.isEmpty { return URL(fileURLWithPath: p) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NotchApp/mac-buffer.json")
    }
    static func load(from url: URL, now: Date = Date()) -> [MailItem] {
        guard let d = try? Data(contentsOf: url) else { return [] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return prune((try? dec.decode([MailItem].self, from: d)) ?? [], now: now)
    }
    static func save(_ items: [MailItem], to url: URL, now: Date = Date()) {
        let keep = prune(items, now: now)
        guard !keep.isEmpty else { try? FileManager.default.removeItem(at: url); return }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        guard let d = try? enc.encode(keep) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)     // notification text: owner-only
    }
}
