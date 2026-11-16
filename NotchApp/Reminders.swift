import Foundation

/// A reminder someone set for you from another assistant ("remind me to call mum at 9"). It arrives as a small file in the vault's Reminders folder.
struct Reminder: Equatable, Sendable {
    let id: String
    let text: String
    let source: String      // chatgpt | claude-web | other-ai
    let due: Date

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
                return Reminder(id: id, text: text, source: (h["source"] as? String) ?? "", due: due)
            }
            .sorted { $0.due < $1.due }
    }

    /// Reminders whose time has come and that haven't been shown (`done`), honouring a snooze. Oldest first.
    static func due(_ all: [Reminder], done: [String], snoozed: [String: Date], now: Date) -> [Reminder] {
        let finished = Set(done)
        return all.filter { !finished.contains($0.id) && (snoozed[$0.id] ?? $0.due) <= now }
    }
}
