import Foundation

/// The pure half of dictation (no Speech, no AppKit), so it can be tested.
enum DictationLogic {
    /// Trimmed transcript, or nil when there is nothing worth asking.
    static func cleaned(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// settings.json: `"voice": { "locale": "en-US", "allow_apple_server": false }`, both optional.
    static func voice(at url: URL) -> (locale: Locale, allowServer: Bool) {
        let v = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["voice"] as? [String: Any]
        let id = (v?["locale"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return (id.map { Locale(identifier: $0) } ?? .current, (v?["allow_apple_server"] as? Bool) == true)
    }

    /// settings.json: `"voice": { "enabled": false }` turns the hold-to-ask key off (a hold then behaves like a tap). On by default.
    static func enabled(at url: URL) -> Bool {
        let v = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["voice"] as? [String: Any]
        return (v?["enabled"] as? Bool) != false
    }
    static func setEnabled(at url: URL, _ on: Bool) throws {
        try Settings.mutate(at: url) { root in
            var v = root["voice"] as? [String: Any] ?? [:]
            if on { v.removeValue(forKey: "enabled") } else { v["enabled"] = false }
            if v.isEmpty { root.removeValue(forKey: "voice") } else { root["voice"] = v }
        }
    }

    // MARK: languages  (settings.json: "voice": { "locale": "hi-IN", "languages": ["en-US", "hi-IN"] }, at most 3, no auto-detect)

    static let maxLanguages = 3

    /// "hi_IN" and "hi-in" are the same language; ids are kept as `xx-YY`.
    static func normalized(_ id: String) -> String {
        let t = id.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "_", with: "-")
        let parts = t.split(separator: "-", maxSplits: 1).map(String.init)
        guard let lang = parts.first else { return "" }
        return parts.count == 2 ? lang.lowercased() + "-" + parts[1] : lang.lowercased()
    }

    /// The quick-switch set: the primary first, then the rest in order, de-duplicated, empty entries dropped, at most 3.
    static func languages(primary: String?, list: [String]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for raw in [primary ?? ""] + list {
            let id = normalized(raw)
            if !id.isEmpty, seen.insert(id.lowercased()).inserted { out.append(id) }
        }
        return Array(out.prefix(maxLanguages))
    }

    /// The language after `current`, wrapping round; the first one when `current` isn't in the list.
    static func next(after current: String, in list: [String]) -> String? {
        guard !list.isEmpty else { return nil }
        let i = list.firstIndex { normalized($0).lowercased() == normalized(current).lowercased() }
        return list[((i ?? -1) + 1) % list.count]
    }

    /// Apple's "multiple languages, India" model: Hindi and English in one sentence.
    static let hinglish = "mul-IN"
    static func isHinglish(_ id: String) -> Bool { normalized(id).lowercased() == hinglish.lowercased() }

    /// "hi-IN" -> "HI", the language chip. Hinglish is "HG".
    static func code(for id: String) -> String {
        isHinglish(id) ? "HG" : String(normalized(id).split(separator: "-").first ?? "").uppercased()
    }

    /// The primary language and the stored quick-switch list, in the order saved (primary included).
    static func stored(at url: URL) -> (primary: String, list: [String]) {
        let v = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["voice"] as? [String: Any]
        let saved = normalized((v?["locale"] as? String) ?? "")
        let primary = saved.isEmpty ? Locale.current.identifier(.bcp47) : saved
        let list = languages(primary: nil, list: (v?["languages"] as? [String]) ?? [])
        return (primary, list.contains { $0.lowercased() == primary.lowercased() } ? list : languages(primary: primary, list: list))
    }

    /// Saves the choice, keeping every other key (including `allow_apple_server`). `languages` first element is the primary.
    static func save(at url: URL, languages ids: [String]) throws {
        let all = languages(primary: nil, list: ids)
        try Settings.mutate(at: url) { root in
            var v = root["voice"] as? [String: Any] ?? [:]
            if let first = all.first { v["locale"] = first }
            if all.count > 1 { v["languages"] = all } else { v.removeValue(forKey: "languages") }
            root["voice"] = v
        }
    }

    /// Only the primary changes (the chip); the saved list and its order stay put so cycling keeps going round.
    static func setPrimary(at url: URL, _ id: String) throws {
        try Settings.mutate(at: url) { root in
            var v = root["voice"] as? [String: Any] ?? [:]
            v["locale"] = normalized(id)
            root["voice"] = v
        }
    }
}

// MARK: model downloads (pure: the queue, the error wording, the reserve limit, what older macOS lacks)

/// Downloads run one at a time, in the order they were asked for. A language is never queued twice.
struct DownloadQueue: Equatable {
    private(set) var items: [String] = []
    private static func k(_ id: String) -> String { DictationLogic.normalized(id).lowercased() }
    func contains(_ id: String) -> Bool { items.contains { Self.k($0) == Self.k(id) } }
    mutating func add(_ id: String) { if !contains(id) { items.append(id) } }
    mutating func remove(_ id: String) { items.removeAll { Self.k($0) == Self.k(id) } }
    mutating func pop() -> String? { items.isEmpty ? nil : items.removeFirst() }
}

enum ReserveDecision: Equatable { case ok, release([String]), full(Int) }

extension DictationLogic {
    /// The macOS 26 engine keeps at most `max` languages reserved. Already holding it, or room left: fine. Otherwise release only as many
    /// reserved languages outside `keep` as needed (first reserved first); if that can't make room, it is full.
    static func reserveDecision(reserved: [String], keep: Set<String>, wanted: String, max: Int) -> ReserveDecision {
        let w = wanted.lowercased()
        if reserved.contains(where: { $0.lowercased() == w }) || reserved.count < max { return .ok }
        let need = reserved.count - max + 1
        let spare = reserved.filter { !keep.contains($0.lowercased()) && $0.lowercased() != w }
        return spare.count >= need ? .release(Array(spare.prefix(need))) : .full(max)
    }

    static func reserveFullMessage(_ max: Int) -> String { "Your Mac can keep \(max) voice languages for Dex Notch. Remove one to add another." }

    /// A human line for a failed download. The technical detail goes to the log, not here.
    static func downloadMessage(domain: String, code: Int, name: String) -> String {
        let offline = [-1009, -1005, -1001, -1004, -1018, -1020]       // not connected, connection lost, timed out, can't connect, roaming off, data off
        if domain == NSURLErrorDomain, offline.contains(code) { return "No internet connection. Try again when you're online." }
        return "Couldn't download \(name) (\(code)). Try again."
    }

    /// Languages Apple's macOS 26 engine can do that the older engine can't do on this Mac. A short hand-kept list (checked against
    /// SpeechTranscriber.supportedLocales and the old engine's on-device set); anything missing here just isn't tagged.
    static let needsMacOS26: Set<String> = ["hi-in", "mul-in", "ur-in", "bn-in", "ta-in", "te-in", "mr-in", "gu-in", "kn-in", "ml-in", "pa-in",
                                            "de-de", "fr-fr", "es-es", "es-mx", "it-it", "pt-br", "ja-jp", "ko-kr", "zh-cn", "zh-tw", "yue-cn"]
    static func needsMacOS26(_ id: String) -> Bool { needsMacOS26.contains(normalized(id).lowercased()) }

    /// What to use when the stored language can't run here: itself if it can, else English (en-US first), else the first one that can.
    static func fallback(for wanted: String, available: [String]) -> String? {
        let w = normalized(wanted).lowercased()
        if let hit = available.first(where: { normalized($0).lowercased() == w }) { return hit }
        return available.first { normalized($0).lowercased() == "en-us" } ?? available.first { normalized($0).lowercased().hasPrefix("en") } ?? available.first
    }
}

/// One key, two meanings: a quick tap and a hold. The caller starts a threshold timer on `press`, calls `thresholdPassed` when it fires,
/// and acts on `release`. Autorepeat presses are ignored. If a release is ever lost, a press more than `stale` seconds after the last one
/// counts as fresh, so the key can't stay dead.
struct TapOrHold {
    static let threshold: TimeInterval = 0.25
    static let stale: TimeInterval = 2
    enum Release { case tap, endHold, ignored }
    private var down = false
    private var holding = false
    private var last = Date.distantPast

    mutating func press(at now: Date = Date()) -> Bool {
        defer { last = now }
        if down && now.timeIntervalSince(last) < Self.stale { return false }
        down = true; holding = false; return true
    }
    /// True once, if the key is still down: the hold begins.
    mutating func thresholdPassed() -> Bool { guard down, !holding else { return false }; holding = true; return true }
    mutating func release() -> Release {
        guard down else { return .ignored }
        down = false
        defer { holding = false }
        return holding ? .endHold : .tap
    }
}
