import Foundation

/// The pure half of dictation (no Speech, no AppKit), so it can be tested.
enum DictationLogic {
    /// Trimmed transcript, or nil when there is nothing worth pasting.
    static func cleaned(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// Put the old clipboard back only if nobody (the user, another app) has written to it since we did.
    static func shouldRestore(setCount: Int, currentCount: Int) -> Bool { setCount == currentCount }

    /// settings.json: `"voice": { "locale": "en-US", "allow_apple_server": false }`, both optional.
    static func voice(at url: URL) -> (locale: Locale, allowServer: Bool) {
        let v = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["voice"] as? [String: Any]
        let id = (v?["locale"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return (id.map { Locale(identifier: $0) } ?? .current, (v?["allow_apple_server"] as? Bool) == true)
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
