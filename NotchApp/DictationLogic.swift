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
