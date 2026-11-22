import AVFoundation
import Speech

#if compiler(>=6.2)
/// macOS 26+ engine: mic buffers -> AVAudioConverter -> SpeechAnalyzer + SpeechTranscriber, all on this Mac (the model is a system asset).
/// Built nonisolated on purpose: the tap runs on the realtime audio thread and the results loop off the main actor (Swift 6 isolation).
@available(macOS 26, *)
final class AnalyzerRun: @unchecked Sendable {
    private let analyzer: SpeechAnalyzer
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let converter: AVAudioConverter
    private let target: AVAudioFormat
    private var results: Task<Void, Never>?

    private init(analyzer: SpeechAnalyzer, continuation: AsyncStream<AnalyzerInput>.Continuation, converter: AVAudioConverter, target: AVAudioFormat) {
        self.analyzer = analyzer; self.continuation = continuation; self.converter = converter; self.target = target
    }

    nonisolated static func make(locale: Locale, input: AVAudioFormat, _ mine: Int) async throws -> AnalyzerRun {
        let t = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
        guard let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t]), let conv = AVAudioConverter(from: input, to: fmt) else { throw CocoaError(.featureUnsupported) }
        let (stream, cont) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let analyzer = SpeechAnalyzer(modules: [t])
        try await analyzer.start(inputSequence: stream)
        let run = AnalyzerRun(analyzer: analyzer, continuation: cont, converter: conv, target: fmt)
        run.results = Task.detached {
            var done = "", volatile = ""      // finalized text so far + the current guess
            do {
                for try await r in t.results {
                    let s = String(r.text.characters)
                    if r.isFinal { done = Self.join(done, s); volatile = "" } else { volatile = s }
                    let live = Self.join(done, volatile)
                    await MainActor.run { Dictation.shared.heard(live, final: false, mine) }
                }
            } catch {}
            let all = Self.join(done, volatile)
            await MainActor.run { Dictation.shared.heard(all, final: true, mine) }
        }
        return run
    }

    nonisolated private static func join(_ a: String, _ b: String) -> String {
        guard let l = a.last, let f = b.first, !l.isWhitespace, !f.isWhitespace else { return a + b }
        return a + " " + b
    }

    nonisolated func tapBlock(_ mine: Int) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { [self] buf, _ in
            if let level = Dictation.level(buf) { Task { @MainActor in Dictation.shared.setLevel(level, mine) } }
            let cap = AVAudioFrameCount(Double(buf.frameLength) * target.sampleRate / buf.format.sampleRate) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return }
            nonisolated(unsafe) var fed = false
            nonisolated(unsafe) let buf = buf      // the converter calls the block synchronously, on this thread
            var err: NSError?
            converter.convert(to: out, error: &err) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true; status.pointee = .haveData; return buf
            }
            if err == nil, out.frameLength > 0 { continuation.yield(AnalyzerInput(buffer: out)) }
        }
    }

    /// Key released: no more audio; the analyzer finalizes what it has and the results loop ends with the final text.
    func end() { continuation.finish(); Task { [analyzer] in try? await analyzer.finalizeAndFinishThroughEndOfInput() } }
    func cancel() { continuation.finish(); results?.cancel(); Task { [analyzer] in await analyzer.cancelAndFinishNow() } }
}
#endif
