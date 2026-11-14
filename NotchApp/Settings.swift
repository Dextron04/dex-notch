import Foundation

/// Where Gemma lives. Read from settings.json so no host or model name is baked into the app.
struct GemmaSettings: Equatable {
    var host: String
    var model: String
    var keychainService: String   // login-keychain item holding the bearer token (defaults to the host)
    var keychainAccount: String
    var base: String { "https://" + host }
}

struct AppSettings: Equatable {
    var gemma: GemmaSettings?
    var gemmaProblem: String?       // the gemma section is there but unusable (the rest of the file still applies)
    var defaultBackend: Backend?
    var workspaceDefault: String?    // folder `+` runs may write to by default (absolute, validated); nil = the scratch sandbox
    var folders: [String]?           // the ⌘F list; nil = the built-in four
    var workspaceProblems: [String] = []
}
enum SettingsLoad: Equatable { case ok(AppSettings), missing, invalid(String) }

/// ~/Library/Application Support/NotchApp/settings.json (every key optional):
///   { "default": "claude", "gemma": { "host": "ai.example.com", "model": "gemma3:12b", "keychain_service": "…", "keychain_account": "…" } }
/// The recorder (Python) reads the same file for its RAG sync.
enum Settings {
    /// $NOTCH_SETTINGS overrides the location (demos, screenshots, trying the first-run flow without touching your real file).
    static var defaultURL: URL {
        if let p = ProcessInfo.processInfo.environment["NOTCH_SETTINGS"], !p.isEmpty { return URL(fileURLWithPath: p) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NotchApp/settings.json")
    }

    static func load(from url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser, exists: (String) -> Bool = { var d: ObjCBool = false; return FileManager.default.fileExists(atPath: $0, isDirectory: &d) && d.boolValue }) -> SettingsLoad {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url), let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .invalid("settings.json isn't valid JSON.")
        }
        let preferred = (root["default"] as? String).flatMap { Backend(rawValue: $0) }

        // workspace: where edit runs may write. Every folder is validated; bad ones are reported and dropped, the rest still apply.
        var problems: [String] = []
        func folder(_ raw: Any) -> String? {
            if let s = raw as? String, let n = normalizeFolder(s, home: home, exists: exists) { return n }
            problems.append("workspace: \(raw) isn't a usable folder (it must exist inside your home folder, and not be a hidden folder or Library).")
            return nil
        }
        let ws = root["workspace"] as? [String: Any]
        let wsDefault = (ws?["default"] as? String).flatMap { $0.isEmpty ? nil : folder($0) }
        var seen = Set<String>()
        let wsFolders = (ws?["folders"] as? [Any]).map { $0.compactMap(folder).filter { seen.insert($0).inserted } }
        func result(_ g: GemmaSettings?, _ problem: String?) -> SettingsLoad {
            .ok(AppSettings(gemma: g, gemmaProblem: problem, defaultBackend: preferred, workspaceDefault: wsDefault, folders: wsFolders, workspaceProblems: problems))
        }

        guard let g = root["gemma"] as? [String: Any] else { return result(nil, nil) }   // Gemma is optional
        let rawHost = ((g["host"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let model = ((g["model"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if rawHost.isEmpty && model.isEmpty { return result(nil, nil) }                    // the blank template: not a problem
        guard !rawHost.isEmpty else { return result(nil, "gemma.host is missing.") }
        guard let host = normalizeHost(rawHost) else { return result(nil, "gemma.host must be a plain hostname such as ai.example.com.") }
        guard !model.isEmpty else { return result(nil, "gemma.model is missing (the model name your server knows, for example gemma3:12b).") }
        return result(GemmaSettings(host: host, model: model,
                                    keychainService: (g["keychain_service"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? host,
                                    keychainAccount: (g["keychain_account"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "notchapp"), nil)
    }

    private static let template = """
    {
      "default": "claude",
      "gemma": {
        "host": "",
        "model": ""
      }
    }

    """

    /// Writes a blank settings.json if there is none (never overwrites). True when it created one.
    static func ensureTemplate(at url: URL) throws -> Bool {
        guard !FileManager.default.fileExists(atPath: url.path) else { return false }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: Data(template.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return true
    }

    /// A folder an edit run may be allowed to write to. Only places inside the home folder, never the home folder itself, never a
    /// hidden top-level folder (~/.ssh, ~/.aws, …) or ~/Library, and it must exist. `..` and symlinks cannot be used to leave home.
    static func normalizeFolder(_ raw: String, home: URL, exists: (String) -> Bool) -> String? {
        var p = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if p == "~" || p.hasPrefix("~/") { p = home.path + p.dropFirst(1) }
        guard p.hasPrefix("/") else { return nil }
        let homePath = home.standardizedFileURL.path
        func inside(_ path: String, _ base: String) -> Bool {
            guard path.hasPrefix(base + "/") else { return false }
            let first = path.dropFirst(base.count + 1).split(separator: "/").first.map(String.init) ?? ""
            return !first.isEmpty && !first.hasPrefix(".") && first != "Library"
        }
        let std = URL(fileURLWithPath: p).standardizedFileURL.path
        guard inside(std, homePath), exists(std) else { return nil }
        let real = URL(fileURLWithPath: std).resolvingSymlinksInPath().path       // a symlink must not lead out of home
        guard inside(real, home.resolvingSymlinksInPath().path) else { return nil }
        return std
    }

    /// Saves what the Settings window collected, keeping every other key in the file as it was.
    static func update(at url: URL, defaultBackend: Backend?, workspaceDefault: String?, folders: [String], gemma: GemmaSettings? = nil, removeGemma: Bool = false) throws {
        var obj: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            guard let d = try? Data(contentsOf: url), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)       // never overwrite a file the user hand-edited into something we can't read
            }
            obj = o
        }
        if let b = defaultBackend { obj["default"] = b.rawValue } else { obj.removeValue(forKey: "default") }
        var ws = obj["workspace"] as? [String: Any] ?? [:]
        if let d = workspaceDefault { ws["default"] = d } else { ws.removeValue(forKey: "default") }
        ws["folders"] = folders
        obj["workspace"] = ws
        if removeGemma { obj.removeValue(forKey: "gemma") }
        if let g = gemma {
            var m: [String: Any] = ["host": g.host, "model": g.model]
            if g.keychainService != g.host { m["keychain_service"] = g.keychainService }
            if g.keychainAccount != "notchapp" { m["keychain_account"] = g.keychainAccount }
            obj["gemma"] = m
        }
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".settings-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        if rename(tmp.path, url.path) != 0 { try? FileManager.default.removeItem(at: tmp); throw CocoaError(.fileWriteUnknown) }
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
