import AVFoundation
import Speech
import os

/// Hold ⌥Space: speak, release, and the words are asked of the notch. On-device recognition only
/// (unless settings.json opts in to Apple's servers). The microphone is open only while the key is held.
@MainActor @Observable
final class Dictation {
    static let shared = Dictation()
    nonisolated static let log = Logger(subsystem: "com.tushin.NotchApp", category: "voice")

    weak var assistant: Assistant?

    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var held = false                 // the key is down (autorepeat presses are ignored while this is true)
    private var session = 0                  // bumped per press; stale callbacks and timers compare against it
    private var latest = ""
    private var analyzer: (end: () -> Void, cancel: () -> Void)?   // the macOS 26 engine, when it is the one running
    /// "EN", "HI": the language the next dictation will use. Observable, shown in the notch's language chip.
    private(set) var currentLanguageCode = DictationLogic.code(for: DictationLogic.stored(at: Settings.defaultURL).primary)

    /// False when a session is already running (the caller must then not stop it).
    @discardableResult
    func start() -> Bool {
        guard !held else { return false }
        finish(session)      // a fast re-press: deliver the previous utterance now instead of dropping it
        held = true; session += 1; latest = ""
        let mine = session
        Task {
            guard await Self.authorized(speech: !Self.usesAnalyzer) else { if held, session == mine { held = false; say("Allow the microphone in System Settings") }; return }
            guard held, session == mine else { return }   // released while the permission sheet was up
            begin(mine)
        }
        return true
    }

    func stop() {
        guard held else { return }
        held = false
        guard engine != nil else { return }
        assistant?.voiceLevel = 0
        let mine = session
        teardownAudio()
        request?.endAudio()
        analyzer?.end()
        // the final result usually lands within a moment; don't wait on it forever
        let wait = analyzer != nil ? 4.0 : 1.5      // the analyzer finalizes the tail of the sentence after the audio ends; cut it short and the last words are lost
        Task { try? await Task.sleep(for: .seconds(wait)); finish(mine) }
    }

    /// The macOS 26 engine (SpeechAnalyzer) is a system asset: the SDK has no authorization API for it, only the microphone is asked for.
    private static var usesAnalyzer: Bool {
        #if compiler(>=6.2)
        if #available(macOS 26, *) { return SpeechTranscriber.isAvailable }
        #endif
        return false
    }

    nonisolated private static func authorized(speech: Bool) async -> Bool {
        guard await AVCaptureDevice.requestAccess(for: .audio) else { return false }
        guard speech else { return true }
        return await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) } }
    }

    private func begin(_ mine: Int) {
        let v = DictationLogic.voice(at: Settings.defaultURL)
        #if compiler(>=6.2)
        if #available(macOS 26, *), Self.usesAnalyzer {      // better than SFSpeechRecognizer for every language it supports, English included
            Task {
                if let loc = await SpeechTranscriber.supportedLocale(equivalentTo: v.locale) { await beginAnalyzer(loc, mine) }
                else if held, session == mine { beginClassic(v, mine) }
            }
            return
        }
        #endif
        beginClassic(v, mine)
    }

    #if compiler(>=6.2)
    @available(macOS 26, *)
    private func beginAnalyzer(_ loc: Locale, _ mine: Int) async {
        guard held, session == mine else { return }
        let key = VoiceLanguages.key(loc)
        guard (await SpeechTranscriber.installedLocales).contains(where: { VoiceLanguages.key($0) == key }) else {
            guard held, session == mine else { return }
            held = false
            let id = loc.identifier(.bcp47)
            if let p = VoiceLanguages.shared.problem { VoiceLanguages.shared.clearProblem(); return say(p) }   // the last download failed: say why, the next try downloads again
            VoiceLanguages.shared.download(id)      // the model comes down once; audio never leaves the Mac
            assistant?.voiceNote("Downloading \(VoiceLanguages.shortName(id))…")
            return
        }
        do {
            try await VoiceLanguages.shared.reserve(loc)
            let eng = AVAudioEngine()
            let input = eng.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { held = false; return say("No microphone found") }   // installTap throws on a 0 Hz format
            let run = try await AnalyzerRun.make(locale: loc, input: format, mine)
            guard held, session == mine else { run.cancel(); return }      // released while the model loaded: the mic never opens
            input.installTap(onBus: 0, bufferSize: 1024, format: format, block: run.tapBlock(mine))
            do { try eng.start() } catch { Self.log.error("engine start failed: \(error.localizedDescription, privacy: .public)"); input.removeTap(onBus: 0); run.cancel(); held = false; return say("Couldn't open the microphone") }
            engine = eng; analyzer = (run.end, run.cancel)
            assistant?.voiceBegan()
            Task { try? await Task.sleep(for: .seconds(60)); if held, session == mine { stop() } }   // release never arrived
        } catch {
            Self.log.error("analyzer start failed: \(error.localizedDescription, privacy: .public)")
            guard session == mine else { return }
            held = false; say("Couldn't start dictation")
        }
    }
    #endif

    private func beginClassic(_ v: (locale: Locale, allowServer: Bool), _ mine: Int) {
        guard held, session == mine else { return }
        guard let rec = SFSpeechRecognizer(locale: v.locale), rec.isAvailable else { held = false; return say("Dictation isn't available right now") }
        if !rec.supportsOnDeviceRecognition && !v.allowServer {
            held = false
            let name = Locale.current.localizedString(forIdentifier: v.locale.identifier) ?? v.locale.identifier
            return say("\(name) isn't available offline on this Mac")
        }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = rec.supportsOnDeviceRecognition   // only false when the person opted in
        let eng = AVAudioEngine()
        let input = eng.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { held = false; return say("No microphone found") }   // installTap throws on a 0 Hz format
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tapBlock(req, mine))
        do { try eng.start() } catch { Self.log.error("engine start failed: \(error.localizedDescription, privacy: .public)"); input.removeTap(onBus: 0); held = false; return say("Couldn't open the microphone") }
        engine = eng; request = req
        assistant?.voiceBegan()
        task = rec.recognitionTask(with: req, resultHandler: Self.resultHandler(mine))
        Task { try? await Task.sleep(for: .seconds(60)); if held, session == mine { stop() } }   // release never arrived
    }

    // Built nonisolated: a closure written inside a @MainActor method inherits main-actor isolation, and Swift 6 traps
    // when AVFoundation (realtime audio thread) or Speech (its own queue) calls it.
    nonisolated private static func tapBlock(_ req: SFSpeechAudioBufferRecognitionRequest, _ mine: Int) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        nonisolated(unsafe) let req = req
        let gate = LevelGate()
        return { buf, _ in
            req.append(buf)
            guard gate.pass(), let level = Dictation.level(buf) else { return }
            Task { @MainActor in Dictation.shared.setLevel(level, mine) }
        }
    }

    /// Lets one level update through every ~33 ms; the audio thread calls this, so it is never shared.
    nonisolated final class LevelGate: @unchecked Sendable {
        private var last: TimeInterval = 0
        func pass() -> Bool { let t = ProcessInfo.processInfo.systemUptime; guard t - last >= 1.0 / 30 else { return false }; last = t; return true }
    }

    nonisolated static func level(_ buf: AVAudioPCMBuffer) -> Float? {
        guard let ch = buf.floatChannelData?[0], buf.frameLength > 0 else { return nil }
        var sum: Float = 0
        for i in 0..<Int(buf.frameLength) { sum += ch[i] * ch[i] }
        return min(1, (sum / Float(buf.frameLength)).squareRoot() * 8)
    }

    nonisolated private static func resultHandler(_ mine: Int) -> @Sendable (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, error in
            let text = result?.bestTranscription.formattedString, final = (result?.isFinal ?? false) || error != nil
            Task { @MainActor in Dictation.shared.heard(text, final: final, mine) }
        }
    }

    func setLevel(_ l: Float, _ mine: Int) {
        guard mine == session, held else { return }
        assistant?.voiceLevel(l)
    }

    func heard(_ text: String?, final: Bool, _ mine: Int) {
        guard mine == session else { return }
        if let text { latest = text; assistant?.voiceHeard(latest) }   // the words become the prompt text, in place
        if final && !held { finish(mine) }
    }

    private func teardownAudio() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    /// Runs once per session (from the final result or the timeout, whichever is first).
    private func finish(_ mine: Int) {
        guard mine == session, !held, task != nil || request != nil || analyzer != nil else { return }
        task?.cancel(); task = nil; request = nil
        analyzer?.cancel(); analyzer = nil
        teardownAudio()
        let text = DictationLogic.cleaned(latest)
        latest = ""
        assistant?.voiceEnded(text)     // nil (nothing heard) leaves the notch open and focused
    }

    private func say(_ s: String) { assistant?.voiceFailed(s) }

    // MARK: language

    func refreshLanguage() {
        currentLanguageCode = DictationLogic.code(for: DictationLogic.stored(at: Settings.defaultURL).primary)
        VoiceLanguages.shared.reload()
    }

    /// The chip in the notch: the next language in the quick-switch set, saved to settings.json. Ignored while a dictation is running.
    func cycleLanguage() {
        guard !held else { return }
        let s = DictationLogic.stored(at: Settings.defaultURL)
        guard s.list.count > 1, let next = DictationLogic.next(after: s.primary, in: s.list) else { return }
        do { try DictationLogic.setPrimary(at: Settings.defaultURL, next) } catch { return say("Couldn't save the language") }
        refreshLanguage()
    }
}
