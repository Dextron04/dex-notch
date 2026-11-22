import SwiftUI

/// ⌥V dictation, hung under the closed notch. Three moments:
/// start: the capsule blooms out of the notch (spring) with a one-shot ember rim;
/// listening: an ember waveform breathes with your voice, an ember glow seeps under the capsule, the newest words slide in and the oldest fade off the left;
/// sent: the words collapse into a spark that streaks up into the notch, then the capsule folds away.
/// Messages get a quiet fade (no bounce, no spark). Pure function of `state`, so previews need no mic.
struct DictationBar: View {
    let state: Dictation.State
    let notch: CGSize
    @Environment(\.accessibilityReduceMotion) private var reduce

    private enum Phase { case hidden, listening, sent, message }
    @State private var phase: Phase = .hidden
    @State private var partial = ""
    @State private var message = ""
    @State private var level: Float = 0           // smoothed: fast attack, slow release
    @State private var collapsed = false          // sent: words folded into the spark
    @State private var spark = false
    @State private var sending: Task<Void, Never>?

    private static let height: CGFloat = 28
    private static let wordsW: CGFloat = 124

    var body: some View {
        ZStack(alignment: .top) {
            if phase != .hidden {
                capsule
                    .padding(.top, notch.height + 6)
                    .transition(reduce ? .opacity : .scale(scale: 0.35, anchor: .top).combined(with: .opacity))
            }
        }
        .animation(reduce ? .easeOut(duration: 0.15) : .spring(duration: 0.3, bounce: 0.35), value: phase == .hidden)
        .animation(reduce ? .easeOut(duration: 0.15) : .smooth(duration: 0.25), value: phase == .message)
        .allowsHitTesting(false)
        .onChange(of: state) { _, new in update(new) }
    }

    // MARK: pieces

    private var capsule: some View {
        ZStack {
            if phase == .message {
                HStack(spacing: 7) {
                    Circle().fill(Ink.ember).frame(width: 5, height: 5).opacity(0.75)
                    Text(message).lineLimit(1)
                }
                .foregroundStyle(Ink.text.opacity(0.9))
                .transition(.opacity)
            } else {
                listening.transition(.opacity)
            }
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 12).frame(height: Self.height)
        .frame(maxWidth: 320)
        .background(.black, in: Capsule())
        .background(alignment: .bottom) { glow }
        .overlay { if !reduce { Bloom() } }
        .overlay { if spark && !reduce { Spark(rise: notch.height / 2 + 6 + Self.height / 2) } }
        .fixedSize()
    }

    private var listening: some View {
        HStack(spacing: 8) {
            Wave(level: level, still: reduce, live: phase == .listening).frame(width: 54, height: 20)
            words.frame(width: Self.wordsW, height: 16)
            Text(Dictation.shared.currentLanguageCode)       // fixed width: never nudges the words
                .font(.system(size: 9, weight: .semibold)).foregroundStyle(Ink.dim).frame(width: 18)
        }
        .scaleEffect(collapsed ? 0.08 : 1).opacity(collapsed ? 0 : 1).blur(radius: collapsed ? 3 : 0)
        .animation(.easeIn(duration: 0.2), value: collapsed)
    }

    /// Newest words only, keyed by their position in the sentence so existing words stay put and new ones slide in.
    private var words: some View {
        let all = partial.split(whereSeparator: \.isWhitespace).map(String.init)
        let from = max(0, all.count - 4)
        return ZStack(alignment: .trailing) {
            if all.isEmpty { Text("Listening…").foregroundStyle(Ink.dim).transition(.opacity) }
            HStack(spacing: 4) {
                ForEach(from..<all.count, id: \.self) { i in
                    Text(all[i]).fixedSize()
                        .transition(reduce ? .opacity : .asymmetric(insertion: .offset(y: 8).combined(with: .opacity), removal: .opacity))
                }
            }
            .foregroundStyle(Ink.text)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .clipped()
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.28)], startPoint: .leading, endPoint: .trailing))
        .animation(reduce ? .easeOut(duration: 0.15) : .smooth(duration: 0.22), value: all.count)
    }

    /// Ember light bleeding out under the capsule, stronger as you speak.
    private var glow: some View {
        Ellipse()
            .fill(RadialGradient(colors: [Ink.emberDeep.opacity(0.55), .clear], center: .center, startRadius: 0, endRadius: 70))
            .frame(width: 190, height: 34).offset(y: 14)
            .opacity(phase == .listening ? 0.12 + 0.88 * Double(level) : 0)
            .animation(.easeOut(duration: 0.12), value: level)
    }

    // MARK: state

    private func update(_ s: Dictation.State) {
        switch s {
        case .listening(let p, let l):
            if phase != .listening { sending?.cancel(); collapsed = false; spark = false; phase = .listening }
            partial = p
            let target = Float(pow(Double(l), 0.7))
            level += (target - level) * (target > level ? 0.7 : 0.18)
        case .message(let m):
            sending?.cancel(); message = m; phase = .message
        case .idle:
            guard phase == .listening else { if phase == .message { phase = .hidden }; return }
            level = 0
            if partial.isEmpty || reduce { phase = .hidden; partial = ""; return }
            sent()
        }
    }

    /// Words fold into a spark, the spark runs up into the notch, then the capsule retracts.
    private func sent() {
        phase = .sent
        collapsed = true; spark = true
        sending = Task {
            try? await Task.sleep(for: .milliseconds(380))
            guard !Task.isCancelled else { return }
            phase = .hidden; spark = false; partial = ""
        }
    }
}

/// Eleven ember bars: centre-weighted, breathing with the smoothed level, with a faint shimmer in silence.
struct Wave: View {
    let level: Float
    let still: Bool
    let live: Bool

    var body: some View {
        // paused whenever nothing is listening, so an idle app draws no frames
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !live || still)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let n = 11, pitch: CGFloat = 5, w: CGFloat = 2.5
                let x0 = (size.width - CGFloat(n - 1) * pitch - w) / 2
                for i in 0..<n {
                    let env = 1 - 0.5 * abs(Double(i) - 5) / 5
                    let wob = still ? 0.7 : 0.5 + 0.5 * sin(t * 7 + Double(i) * 0.9)
                    let amp = min(1, 0.1 * (still ? 0 : 0.5 + 0.5 * sin(t * 2.2 + Double(i) * 0.6)) + Double(level) * env * (0.55 + 0.45 * wob))
                    let h = 3 + (size.height - 3) * amp
                    let r = CGRect(x: x0 + CGFloat(i) * pitch, y: (size.height - h) / 2, width: w, height: h)
                    ctx.fill(Path(roundedRect: r, cornerRadius: w / 2), with: .color(Ink.ember.opacity(0.5 + 0.5 * amp)))
                }
            }
        }
    }
}

/// One-shot ember rim as the capsule blooms open.
private struct Bloom: View {
    @State private var done = false
    var body: some View {
        Capsule().strokeBorder(Ink.ember, lineWidth: 1)
            .opacity(done ? 0 : 0.8)
            .onAppear { withAnimation(.easeOut(duration: 0.55)) { done = true } }
    }
}

/// Flash at the centre, then a streak that runs up into the notch.
private struct Spark: View {
    let rise: CGFloat
    @State private var go = false
    var body: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [Ink.ember, .clear], center: .center, startRadius: 0, endRadius: 14))
                .frame(width: 28, height: 28).scaleEffect(go ? 1.5 : 0.2).opacity(go ? 0 : 1)
            Capsule().fill(LinearGradient(colors: [Ink.ember, Ink.emberDeep.opacity(0)], startPoint: .top, endPoint: .bottom))
                .frame(width: 2.5, height: go ? 20 : 4).offset(y: go ? -rise : 0).opacity(go ? 0.2 : 1)
        }
        .onAppear { withAnimation(.easeIn(duration: 0.3)) { go = true } }
    }
}

// MARK: previews (no mic needed)

private struct Demo: View {
    var cycle = true
    var message: String?
    @State private var state: Dictation.State = .idle
    var body: some View {
        DictationBar(state: state, notch: CGSize(width: 190, height: 32))
            .frame(width: 420, height: 130, alignment: .top)
            .background(Color(white: 0.12))
            .overlay(alignment: .top) { UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10).fill(.black).frame(width: 190, height: 32) }
            .task {
                if let message { state = .message(message); return }
                let said = "remind me to send the invoice before friday afternoon".split(separator: " ").map(String.init)
                repeat {
                    for n in 0...said.count {
                        state = .listening(partial: said.prefix(n).joined(separator: " "), level: n == 0 ? 0 : Float.random(in: 0.2...1))
                        try? await Task.sleep(for: .milliseconds(260))
                        for _ in 0..<3 { state = .listening(partial: said.prefix(n).joined(separator: " "), level: Float.random(in: 0...0.9)); try? await Task.sleep(for: .milliseconds(70)) }
                    }
                    state = .idle
                    try? await Task.sleep(for: .seconds(1.6))
                } while cycle && !Task.isCancelled
            }
    }
}

#Preview("Start, listen, sent (loops)") { Demo() }
#Preview("Listening, silent") { DictationBar(state: .listening(partial: "", level: 0), notch: CGSize(width: 190, height: 32)).frame(width: 420, height: 100, alignment: .top).background(Color(white: 0.12)) }
#Preview("Message") { Demo(message: "Copied, allow Accessibility to paste") }
