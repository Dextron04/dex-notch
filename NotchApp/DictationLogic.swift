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

/// One key, two meanings: a quick tap and a hold. The caller starts a threshold timer on `press`, calls `thresholdPassed` when it fires,
/// and acts on `release`. Autorepeat presses are ignored.
struct TapOrHold {
    static let threshold: TimeInterval = 0.25
    enum Release { case tap, endHold, ignored }
    private var down = false
    private var holding = false

    mutating func press() -> Bool { if down { return false }; down = true; holding = false; return true }
    /// True once, if the key is still down: the hold begins.
    mutating func thresholdPassed() -> Bool { guard down, !holding else { return false }; holding = true; return true }
    mutating func release() -> Release {
        guard down else { return .ignored }
        down = false
        defer { holding = false }
        return holding ? .endHold : .tap
    }
}
