import Foundation

struct SavedTurn: Codable, Equatable { var role: String; var text: String; var verdict: String? = nil; var winner: Backend? = nil } // verdict: Both-mode judge note; optional so old saves decode

struct SavedConversation: Codable, Equatable {
    var version = 1
    var id: String?                        // conversation id: ties the saved chat to its vault note across restarts
    var turns: [SavedTurn] = []
    var backend: Backend = .gemma
    var work = false
    var folder: String?                    // extra folder `+` runs may write to (nil = scratch sandbox only)
    var sessions: [String: String] = [:]   // Backend.rawValue → CLI session id, so follow-ups resume after a restart
    var draft = ""
    var recalled: [String] = []
    var closedAt: Date?
    var title: String?                     // history list: the first question, one line (optional so older saves decode)
    var createdAt: Date?
    var updatedAt: Date?                   // last activity; closedAt is when the notch was last closed
    var vaultTurns: Int?                   // turns already saved to the vault on request (nil/0 = never saved)
    var activity: Date { updatedAt ?? closedAt ?? createdAt ?? .distantPast }
}

/// One small private JSON file holding the open conversation, so quitting or crashing the app doesn't lose it.
enum ConversationStore {
    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchApp/conversation.json")
    }

    static func save(_ c: SavedConversation, to url: URL) throws {
        guard !c.turns.isEmpty || !c.draft.isEmpty else { clear(url); return } // nothing worth keeping
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // private from the first byte (chats can hold anything), then an atomic rename over the old file
        let tmp = dir.appendingPathComponent(".conversation-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: tmp.path, contents: try enc.encode(c), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if rename(tmp.path, url.path) != 0 { try? FileManager.default.removeItem(at: tmp); throw CocoaError(.fileWriteUnknown) }
    }

    /// nil when there is nothing usable: no file, damaged file, a newer format, or away longer than the freshness window.
    static func load(from url: URL, now: Date = Date()) -> SavedConversation? {
        guard let c = read(url) else { return nil }
        if AgentStream.isStale(closedAt: c.closedAt, now: now) { clear(url); return nil }
        return c
    }

    /// Decodes one saved file with no freshness rule (history entries never go stale).
    static func read(_ url: URL) -> SavedConversation? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        guard var c = try? dec.decode(SavedConversation.self, from: data), c.version == 1 else { return nil }
        if c.turns.last?.role == "assistant", c.turns.last?.text.isEmpty == true { c.turns.removeLast() } // answer was cut off mid-flight
        return c.turns.isEmpty && c.draft.isEmpty ? nil : c
    }

    static func clear(_ url: URL) { try? FileManager.default.removeItem(at: url) }
}

/// Every conversation, one private file each (history/<id>.json), so old chats can be browsed and resumed. Local only: nothing here reaches the vault.
enum HistoryStore {
    static var defaultDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NotchApp/history")
    }
    static func fileURL(_ id: String, in dir: URL) -> URL { dir.appendingPathComponent(Journal.safeName(id) + ".json") }

    /// The first question on one line, cut to ~60 characters.
    static func title(_ turns: [SavedTurn]) -> String {
        guard let t = turns.first(where: { $0.role == "user" })?.text else { return "Untitled" }
        let one = t.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return one.count > 60 ? String(one.prefix(59)) + "…" : one
    }

    static func save(_ c: SavedConversation, in dir: URL) throws {
        guard let id = c.id, !c.turns.isEmpty else { return }
        var c = c; c.title = title(c.turns)
        try ConversationStore.save(c, to: fileURL(id, in: dir))
    }
    /// Newest activity first; damaged files and the writer's temp files are skipped.
    static func list(in dir: URL) -> [SavedConversation] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { ConversationStore.read($0) }.filter { !$0.turns.isEmpty }.sorted { $0.activity > $1.activity }
    }
    static func load(_ id: String, in dir: URL) -> SavedConversation? { ConversationStore.read(fileURL(id, in: dir)) }
    static func delete(_ id: String, in dir: URL) { ConversationStore.clear(fileURL(id, in: dir)) }

    /// Today / Yesterday / Previous 7 days / Older, keeping the order given.
    static func grouped(_ items: [SavedConversation], now: Date = Date(), calendar: Calendar = .current) -> [(label: String, items: [SavedConversation])] {
        let today = calendar.startOfDay(for: now)
        func label(_ d: Date) -> String {
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: d), to: today).day ?? 0
            return days <= 0 ? "Today" : days == 1 ? "Yesterday" : days <= 7 ? "Previous 7 days" : "Older"
        }
        var out: [(label: String, items: [SavedConversation])] = []
        for c in items {
            let l = label(c.activity)
            if out.last?.label == l { out[out.count - 1].items.append(c) } else { out.append((l, [c])) }
        }
        return out
    }

    static func matches(_ c: SavedConversation, _ q: String) -> Bool {
        let q = q.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty || (c.title ?? "").localizedStandardContains(q) || c.turns.contains { $0.text.localizedStandardContains(q) }
    }
}
