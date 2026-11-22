import AVFoundation
import Speech

/// Which languages dictation can use on this Mac, whether each one's model is installed, and the download. Drives Settings > Voice
/// and the "download on first use" path in Dictation. macOS 26+: SpeechTranscriber models (system storage, on-device).
/// Older: only the languages SFSpeechRecognizer can do on this Mac without Apple's servers.
@MainActor @Observable
final class VoiceLanguages {
    static let shared = VoiceLanguages()

    enum Status: Equatable { case installed, download, downloading(Double), unavailable }
    struct Option: Hashable { let id: String; let name: String }

    private(set) var options: [Option] = []
    private(set) var selected: [String] = []        // primary first
    private var installedKeys: Set<String> = []
    private var supportedKeys: Set<String> = []
    private var progress: [String: Double] = [:]
    private(set) var problem: String?

    nonisolated static func key(_ l: Locale) -> String { DictationLogic.normalized(l.identifier(.bcp47)).lowercased() }
    nonisolated static func name(_ id: String) -> String { Locale.current.localizedString(forIdentifier: id) ?? id }

    init() { reload() }

    func reload() { let s = DictationLogic.stored(at: Settings.defaultURL); selected = DictationLogic.languages(primary: s.primary, list: s.list) }

    func status(_ id: String) -> Status {
        let k = DictationLogic.normalized(id).lowercased()
        if let p = progress[k] { return .downloading(p) }
        if installedKeys.contains(k) { return .installed }
        return supportedKeys.contains(k) ? .download : .unavailable
    }

    /// Slot 0 is the primary, 1 and 2 are the extra quick-switch languages; nil clears an extra slot.
    func set(slot: Int, _ id: String?) {
        var l = selected
        if let id { if slot < l.count { l[slot] = id } else { l.append(id) } } else if slot > 0, slot < l.count { l.remove(at: slot) }
        let new = DictationLogic.languages(primary: nil, list: l)
        do { try DictationLogic.save(at: Settings.defaultURL, languages: new); problem = nil } catch { problem = "Couldn't save settings.json." }
        reload(); Dictation.shared.refreshLanguage()
        Task { await refresh() }
    }

    func refresh() async {
        var supported: [Locale] = [], installed: Set<String> = []
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            supported = await SpeechTranscriber.supportedLocales
            installed = Set(await SpeechTranscriber.installedLocales.map(Self.key))
        } else { (supported, installed) = Self.legacy() }
        #else
        (supported, installed) = Self.legacy()
        #endif
        let ids = supported.map { DictationLogic.normalized($0.identifier(.bcp47)) }
        let extra = selected.filter { s in !ids.contains { $0.lowercased() == s.lowercased() } }     // a saved choice this Mac can't offer still shows
        options = (ids + extra).map { Option(id: $0, name: Self.name($0)) }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        supportedKeys = Set(ids.map { $0.lowercased() }); installedKeys = installed
    }

    private static func legacy() -> ([Locale], Set<String>) {
        let on = Array(SFSpeechRecognizer.supportedLocales()).filter { SFSpeechRecognizer(locale: $0)?.supportsOnDeviceRecognition == true }
        return (on, Set(on.map(key)))
    }

    // MARK: macOS 26 models

    func download(_ id: String) {
        #if compiler(>=6.2)
        guard #available(macOS 26, *), progress[DictationLogic.normalized(id).lowercased()] == nil else { return }
        Task { await install(id) }
        #endif
    }

    #if compiler(>=6.2)
    /// AssetInventory only lets an app hold a few languages: drop the ones that aren't in the person's set, then take this one.
    @available(macOS 26, *)
    func reserve(_ loc: Locale) async throws {
        let keep = Set(DictationLogic.stored(at: Settings.defaultURL).list.map { $0.lowercased() } + [Self.key(loc)])
        for r in await AssetInventory.reservedLocales where !keep.contains(Self.key(r)) { await AssetInventory.release(reservedLocale: r) }
        try await AssetInventory.reserve(locale: loc)
    }

    @available(macOS 26, *)
    private func install(_ id: String) async {
        let k = DictationLogic.normalized(id).lowercased()
        progress[k] = 0
        defer { progress[k] = nil }
        do {
            guard let loc = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: id)) else { throw CocoaError(.featureUnsupported) }
            try await reserve(loc)
            let t = SpeechTranscriber(locale: loc, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
            if let req = try await AssetInventory.assetInstallationRequest(supporting: [t]) {
                let p = req.progress
                let poll = Task { while !Task.isCancelled { progress[k] = p.fractionCompleted; try? await Task.sleep(for: .milliseconds(300)) } }
                defer { poll.cancel() }
                try await req.downloadAndInstall()
            }
            problem = nil
        } catch { problem = "Couldn't download \(Self.name(id)): \(error.localizedDescription)" }
        await refresh()
    }
    #endif
}
