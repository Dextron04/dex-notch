import Foundation

struct SavedTurn: Codable, Equatable { var role: String; var text: String }

struct SavedConversation: Codable, Equatable {
    var version = 1
    var id: String?                        // conversation id: ties the saved chat to its vault note across restarts
    var turns: [SavedTurn] = []
    var backend: Backend = .gemma
    var work = false
    var sessions: [String: String] = [:]   // Backend.rawValue → CLI session id, so follow-ups resume after a restart
    var draft = ""
    var recalled: [String] = []
    var closedAt: Date?
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
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // private from the first byte (chats can hold anything), then an atomic rename over the old file
        let tmp = dir.appendingPathComponent(".conversation-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: tmp.path, contents: try enc.encode(c), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if rename(tmp.path, url.path) != 0 { try? FileManager.default.removeItem(at: tmp); throw CocoaError(.fileWriteUnknown) }
    }

    /// nil when there is nothing usable: no file, damaged file, a newer format, or away longer than the freshness window.
    static func load(from url: URL, now: Date = Date()) -> SavedConversation? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        guard var c = try? dec.decode(SavedConversation.self, from: data), c.version == 1 else { return nil }
        if AgentStream.isStale(closedAt: c.closedAt, now: now) { clear(url); return nil }
        if c.turns.last?.role == "assistant", c.turns.last?.text.isEmpty == true { c.turns.removeLast() } // answer was cut off mid-flight
        return c.turns.isEmpty && c.draft.isEmpty ? nil : c
    }

    static func clear(_ url: URL) { try? FileManager.default.removeItem(at: url) }
}
