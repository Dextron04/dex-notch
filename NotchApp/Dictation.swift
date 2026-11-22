import AppKit
import AVFoundation
import Carbon.HIToolbox
import Speech

/// Hold ⌥V anywhere: speak, release, and the words are pasted into the focused field. Raw text, on-device recognition only
/// (unless settings.json opts in to Apple's servers). The microphone is open only while the key is held.
@MainActor @Observable
final class Dictation {
    static let shared = Dictation()

    enum State: Equatable { case idle, listening(partial: String, level: Float), message(String) }
    private(set) var state: State = .idle

    /// Where the words go: pasted into the frontmost app, or asked of the assistant (the notch is open; the clipboard is never touched).
    enum Target { case paste, ask }
    private var target: Target = .paste
    weak var assistant: Assistant?

    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var held = false                 // the key is down (autorepeat presses are ignored while this is true)
    private var session = 0                  // bumped per press; stale callbacks and timers compare against it
    private var latest = ""
    private var clear: Task<Void, Never>?
    private var prompted = false             // ask for Accessibility once per launch

    /// False when a session is already running (the caller must then not stop it).
    @discardableResult
    func start(_ to: Target = .paste) -> Bool {
        guard !held else { return false }
        finish(session)      // a fast re-press: deliver the previous utterance now (to its own target) instead of dropping it
        target = to
        held = true; session += 1; latest = ""
        let mine = session
        clear?.cancel()
        Task {
            guard await Self.authorized() else { if held, session == mine { held = false; say("Allow microphone and speech in System Settings") }; return }
            guard held, session == mine else { return }   // released while the permission sheet was up
            begin(mine)
        }
        return true
    }

    func stop() {
        guard held else { return }
        held = false
        guard engine != nil else { state = .idle; return }
        if target == .ask { assistant?.voiceLevel = 0 }
        let mine = session
        teardownAudio()
        request?.endAudio()
        // the final result usually lands within a moment; don't wait on it forever
        Task { try? await Task.sleep(for: .seconds(1.5)); finish(mine) }
    }

    nonisolated private static func authorized() async -> Bool {
        guard await AVCaptureDevice.requestAccess(for: .audio) else { return false }
        return await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) } }
    }

    private func begin(_ mine: Int) {
        let v = DictationLogic.voice(at: Settings.defaultURL)
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
        do { try eng.start() } catch { input.removeTap(onBus: 0); held = false; return say("Couldn't open the microphone") }
        engine = eng; request = req
        state = .listening(partial: "", level: 0)
        if target == .ask { assistant?.voiceBegan() }
        task = rec.recognitionTask(with: req, resultHandler: Self.resultHandler(mine))
        Task { try? await Task.sleep(for: .seconds(60)); if held, session == mine { stop() } }   // release never arrived
    }

    // Built nonisolated: a closure written inside a @MainActor method inherits main-actor isolation, and Swift 6 traps
    // when AVFoundation (realtime audio thread) or Speech (its own queue) calls it.
    nonisolated private static func tapBlock(_ req: SFSpeechAudioBufferRecognitionRequest, _ mine: Int) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        nonisolated(unsafe) let req = req
        return { buf, _ in
            req.append(buf)
            guard let ch = buf.floatChannelData?[0], buf.frameLength > 0 else { return }
            var sum: Float = 0
            for i in 0..<Int(buf.frameLength) { sum += ch[i] * ch[i] }
            let level = min(1, (sum / Float(buf.frameLength)).squareRoot() * 8)
            Task { @MainActor in Dictation.shared.setLevel(level, mine) }
        }
    }

    nonisolated private static func resultHandler(_ mine: Int) -> @Sendable (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, error in
            let text = result?.bestTranscription.formattedString, final = (result?.isFinal ?? false) || error != nil
            Task { @MainActor in Dictation.shared.heard(text, final: final, mine) }
        }
    }

    private func setLevel(_ l: Float, _ mine: Int) {
        guard mine == session, case .listening(let p, _) = state else { return }
        state = .listening(partial: p, level: l)
        if target == .ask, held { assistant?.voiceLevel(l) }
    }

    private func heard(_ text: String?, final: Bool, _ mine: Int) {
        guard mine == session else { return }
        if let text { latest = text }
        if held, case .listening(_, let l) = state { state = .listening(partial: latest, level: l) }
        if target == .ask, text != nil { assistant?.voiceHeard(latest) }   // the words become the prompt text, in place
        if final && !held { finish(mine) }
    }

    private func teardownAudio() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    /// Runs once per session (from the final result or the timeout, whichever is first).
    private func finish(_ mine: Int) {
        guard mine == session, !held, task != nil || request != nil else { return }
        task?.cancel(); task = nil; request = nil
        teardownAudio()
        let text = DictationLogic.cleaned(latest)
        latest = ""
        state = .idle
        if target == .ask { assistant?.voiceEnded(text); return }   // nil (nothing heard) leaves the notch open and focused
        guard let text else { return }
        paste(text)
    }

    private func say(_ s: String) {
        if target == .ask { state = .idle; assistant?.voiceFailed(s); return }
        state = .message(s)
        clear = Task { try? await Task.sleep(for: .seconds(2.5)); if !Task.isCancelled { state = .idle } }
    }

    // MARK: paste

    private func paste(_ text: String) {
        let pb = NSPasteboard.general
        let saved: [NSPasteboardItem] = (pb.pasteboardItems ?? []).map { old in
            let copy = NSPasteboardItem()
            for t in old.types { if let d = old.data(forType: t) { copy.setData(d, forType: t) } }
            return copy
        }
        pb.clearContents()
        pb.setString(text, forType: .string)
        let ours = pb.changeCount
        guard AXIsProcessTrusted() else {
            if !prompted { prompted = true; _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) }
            return say("Copied, allow Accessibility to paste")     // the transcript stays on the clipboard
        }
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: CGEventSource(stateID: .combinedSessionState), virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: down)
            e?.flags = .maskCommand      // exactly ⌘: a still-held ⌥ would make it ⌥⌘V
            e?.post(tap: .cghidEventTap)
        }
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard DictationLogic.shouldRestore(setCount: ours, currentCount: pb.changeCount) else { return }
            pb.clearContents()
            if !saved.isEmpty { pb.writeObjects(saved) }
        }
    }
}
