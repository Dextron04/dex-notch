import AVFoundation
import Speech
import os

/// Which languages dictation can use on this Mac, whether each one's model is installed, and the download. Drives Settings > Voice
/// and the "download on first use" path in Dictation. macOS 26+: SpeechTranscriber models (system storage, on-device).
/// Older: only the languages SFSpeechRecognizer can do on this Mac without Apple's servers.
@MainActor @Observable
final class VoiceLanguages {
    static let shared = VoiceLanguages()
    nonisolated private static let log = Logger(subsystem: "com.tushin.NotchApp", category: "voice")

    enum Status: Equatable { case installed, download, queued, downloading(Double), failed(String), unavailable }
    struct Option: Hashable { let id: String; let name: String; let locked: Bool }    // locked: needs macOS 26, shown greyed out on older Macs

    private(set) var options: [Option] = []
    private(set) var selected: [String] = []        // primary first
    private var installedKeys: Set<String> = []
    private var supportedKeys: Set<String> = []
    private var progress: [String: Double] = [:]
    private(set) var detail: [String: String] = [:] // "42% of 180 MB"
    private var failed: [String: String] = [:]
    private var queue = DownloadQueue()
    private var runner: Task<Void, Never>?
    private var current: String?
    private var cancelled = false
    private var activeProgress: Progress?
    private(set) var problem: String?

    static var modern: Bool { ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)) }

    struct ReserveFull: Error { let max: Int; var message: String { DictationLogic.reserveFullMessage(max) } }

    nonisolated static func key(_ l: Locale) -> String { DictationLogic.normalized(l.identifier(.bcp47)).lowercased() }
    /// "Hindi", for a one-line message.
    nonisolated static func shortName(_ id: String) -> String {
        DictationLogic.isHinglish(id) ? "Hinglish" : Locale.current.localizedString(forLanguageCode: String(DictationLogic.normalized(id).split(separator: "-").first ?? "")) ?? id
    }
    /// A failed download's message, handed over once (the next voice attempt says it, the one after retries).
    func takeFailure(_ id: String) -> String? {
        let k = DictationLogic.normalized(id).lowercased()
        defer { failed[k] = nil; problem = nil }
        return failed[k]
    }
    nonisolated static func name(_ id: String) -> String {
        DictationLogic.isHinglish(id) ? "Hinglish · Hindi + English (India)" : Locale.current.localizedString(forIdentifier: id) ?? id
    }

    /// Hinglish goes first for people in India or who picked Hindi; everything else stays A to Z.
    private var hinglishFirst: Bool { Locale.current.region?.identifier == "IN" || selected.contains { DictationLogic.normalized($0).lowercased().hasPrefix("hi-") } }

    init() { reload() }

    func reload() { let s = DictationLogic.stored(at: Settings.defaultURL); selected = DictationLogic.languages(primary: s.primary, list: s.list) }

    func status(_ id: String) -> Status {
        let k = DictationLogic.normalized(id).lowercased()
        if let p = progress[k] { return .downloading(p) }
        if queue.contains(id) { return .queued }
        if let f = failed[k] { return .failed(f) }
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
        Task {
            await refresh()
            if let id, status(id) == .download { download(id) }      // a language you just added is ready before you need it
        }
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
        let locked = Self.modern ? [] : DictationLogic.needsMacOS26.map { DictationLogic.normalized($0) }.filter { l in !ids.contains { $0.lowercased() == l.lowercased() } && !extra.contains { $0.lowercased() == l.lowercased() } }
        options = (ids + extra + locked).map { Option(id: $0, name: Self.name($0), locked: locked.contains($0)) }.sorted {
            if hinglishFirst, DictationLogic.isHinglish($0.id) != DictationLogic.isHinglish($1.id) { return DictationLogic.isHinglish($0.id) }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        supportedKeys = Set(ids.map { $0.lowercased() }); installedKeys = installed
    }

    nonisolated static func legacy() -> ([Locale], Set<String>) {
        let on = Array(SFSpeechRecognizer.supportedLocales()).filter { SFSpeechRecognizer(locale: $0)?.supportsOnDeviceRecognition == true }
        return (on, Set(on.map(key)))
    }

    // MARK: macOS 26 models

    /// Queue one language; downloads run one at a time, in the order asked.
    func download(_ id: String) {
        #if compiler(>=6.2)
        guard #available(macOS 26, *) else { return }
        let k = DictationLogic.normalized(id).lowercased()
        guard progress[k] == nil, !queue.contains(id) else { return }
        failed[k] = nil; problem = nil
        queue.add(id)
        guard runner == nil else { return }
        runner = Task {
            while let next = queue.pop() { await install(next) }
            runner = nil
        }
        #endif
    }

    /// Every chosen language that is still missing, in the order chosen.
    var missing: [String] { selected.filter { status($0) == .download } }
    func downloadAll() { for id in missing { download(id) } }

    func cancel(_ id: String) {
        let k = DictationLogic.normalized(id).lowercased()
        if progress[k] != nil { cancelled = true; activeProgress?.cancel() } else { queue.remove(id) }
    }

    #if compiler(>=6.2)
    /// AssetInventory only lets an app hold a few languages (`maximumReservedLocales`, read from the system): release the ones that aren't
    /// in the person's set if that makes room, otherwise say the Mac is full.
    @available(macOS 26, *)
    func reserve(_ loc: Locale) async throws {
        var keep: Set<String> = [Self.key(loc)]
        for id in DictationLogic.stored(at: Settings.defaultURL).list {      // the system's own spelling of each chosen language, so keys match what is reserved
            keep.insert(Self.key(await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: id)) ?? Locale(identifier: id)))
        }
        let reserved = await AssetInventory.reservedLocales
        switch DictationLogic.reserveDecision(reserved: reserved.map(Self.key), keep: keep, wanted: Self.key(loc), max: AssetInventory.maximumReservedLocales) {
        case .ok: break
        case .full(let n): throw ReserveFull(max: n)
        case .release(let keys): for r in reserved where keys.contains(Self.key(r)) { await AssetInventory.release(reservedLocale: r) }
        }
        do { try await AssetInventory.reserve(locale: loc) } catch {
            // already holding it is success; anything else is real
            if await AssetInventory.reservedLocales.contains(where: { Self.key($0) == Self.key(loc) }) { return }
            throw error
        }
    }

    @available(macOS 26, *)
    private func install(_ id: String) async {
        let k = DictationLogic.normalized(id).lowercased()
        progress[k] = 0; detail[k] = nil; cancelled = false
        defer { progress[k] = nil; detail[k] = nil; activeProgress = nil }
        var step = "locale"
        for attempt in 1...2 {      // one automatic retry, a few seconds later
            do {
                guard let loc = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: id)) else { throw CocoaError(.featureUnsupported) }
                step = "reserve"
                try await reserve(loc)
                step = "download"
                let t = SpeechTranscriber(locale: loc, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
                if let req = try await AssetInventory.assetInstallationRequest(supporting: [t]) {
                    let p = req.progress
                    activeProgress = p
                    let poll = Task { while !Task.isCancelled { progress[k] = p.fractionCompleted; detail[k] = Self.describe(p); try? await Task.sleep(for: .milliseconds(300)) } }
                    defer { poll.cancel() }
                    try await req.downloadAndInstall()
                }
                problem = nil; failed[k] = nil
                Dictation.shared.assistant?.voiceNote("\(Self.shortName(id)) ready, hold ⌥Space")
                break
            } catch {
                let e = error as NSError
                Self.log.error("download failed attempt=\(attempt) step=\(step, privacy: .public) locale=\(id, privacy: .public) domain=\(e.domain, privacy: .public) code=\(e.code) \(e.localizedDescription, privacy: .public)")
                if cancelled { break }                                  // the person stopped it: no marker, no message
                let full = error as? ReserveFull
                if attempt == 1, full == nil { try? await Task.sleep(for: .seconds(3)); if cancelled { break }; progress[k] = 0; continue }
                let m = full?.message ?? DictationLogic.downloadMessage(domain: e.domain, code: e.code, name: Self.shortName(id))
                failed[k] = m; problem = m
                break
            }
        }
        await refresh()
    }

    /// "42% of 180 MB" when the progress counts bytes, else just the percent.
    private static func describe(_ p: Progress) -> String {
        let pct = "\(Int(p.fractionCompleted * 100))%"
        guard p.totalUnitCount > 100_000 else { return pct }
        return pct + " of " + ByteCountFormatter.string(fromByteCount: p.totalUnitCount, countStyle: .file)
    }
    #endif
}
