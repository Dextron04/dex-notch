import Foundation

/// Where Gemma lives. Read from settings.json so no host or model name is baked into the app.
struct GemmaSettings: Equatable {
    var host: String
    var model: String
    var keychainService: String   // login-keychain item holding the bearer token (defaults to the host)
    var keychainAccount: String
    var base: String { "https://" + host }
}

enum SettingsLoad: Equatable { case ok(GemmaSettings), missing, invalid(String) }

/// ~/Library/Application Support/NotchApp/settings.json:
///   { "gemma": { "host": "ai.example.com", "model": "gemma3:12b", "keychain_service": "…", "keychain_account": "…" } }
/// The recorder (Python) reads the same file for its RAG sync.
enum Settings {
    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NotchApp/settings.json")
    }

    static func load(from url: URL) -> SettingsLoad {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url), let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .invalid("settings.json isn't valid JSON.")
        }
        guard let g = root["gemma"] as? [String: Any] else { return .invalid("settings.json needs a \"gemma\" section with host and model.") }
        guard let rawHost = g["host"] as? String, !rawHost.isEmpty else { return .invalid("gemma.host is missing.") }
        guard let host = normalizeHost(rawHost) else { return .invalid("gemma.host must be a plain hostname such as ai.example.com.") }
        guard let model = (g["model"] as? String)?.trimmingCharacters(in: .whitespaces), !model.isEmpty else {
            return .invalid("gemma.model is missing (the model name your server knows, for example gemma3:12b).")
        }
        return .ok(GemmaSettings(host: host, model: model,
                                 keychainService: (g["keychain_service"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? host,
                                 keychainAccount: (g["keychain_account"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "notchapp"))
    }

    /// The bearer token is sent to this host, so it must be a bare hostname (optionally :port). A pasted "https://host/" is tidied.
    static func normalizeHost(_ s: String) -> String? {
        var h = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.lowercased().hasPrefix("https://") { h = String(h.dropFirst(8)) }
        if h.hasSuffix("/") { h.removeLast() }
        guard h.range(of: #"^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?\z"#, options: .regularExpression) != nil else { return nil }
        if let colon = h.lastIndex(of: ":"), (Int(h[h.index(after: colon)...]) ?? 0) > 65535 { return nil }
        return h
    }
}
