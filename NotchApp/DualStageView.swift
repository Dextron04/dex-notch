import SwiftUI

/// The Both run's progress: the two marks reacting to the step, and four pips (Answering · Judging · Drafting · Reviewing)
/// with an ember ring that slides between them. Motion is one signature spring (~0.4s, small bounce); reduce-motion gets fades only.
struct DualStageView: View {
    let stage: DualStage
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Namespace private var ring

    private static let names = ["Answering", "Judging", "Drafting", "Reviewing"]
    private var index: Int {
        switch stage { case .answering: 0; case .judging: 1; case .drafting: 2; case .reviewing: 3 }
    }
    private var spring: Animation { reduce ? .easeOut(duration: 0.15) : .spring(duration: 0.4, bounce: 0.25) }

    var body: some View {
        HStack(spacing: 14) {
            DualMarks(stage: stage, reduce: reduce)
            HStack(spacing: 12) {
                ForEach(0..<4, id: \.self) { i in pip(i) }
            }
            Spacer(minLength: 0)
        }
        .animation(spring, value: index)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Self.names[index]), step \(index + 1) of 4")
    }

    private func pip(_ i: Int) -> some View {
        let done = i < index, now = i == index
        return HStack(spacing: 5) {
            ZStack {
                if now {
                    PulseRing(reduce: reduce).matchedGeometryEffect(id: "ring", in: ring)
                }
                Circle().fill(done || now ? Ink.ember : Color.clear).frame(width: 5, height: 5)
                    .overlay(Circle().stroke(Ink.dim.opacity(done || now ? 0 : 0.6), lineWidth: 1))
            }.frame(width: 13, height: 13)
            Text(Self.names[i]).font(.system(size: 11, weight: .medium)).tracking(0.3)
                .foregroundStyle(now ? Ink.text : Ink.dim.opacity(done ? 0.9 : 0.6))
        }
    }
}

private struct PulseRing: View {
    let reduce: Bool
    var body: some View {
        TimelineView(.animation(paused: reduce)) { ctx in
            let s = reduce ? 0.5 : (sin(ctx.date.timeIntervalSinceReferenceDate * 2 * .pi / 1.4) + 1) / 2
            Circle().stroke(Ink.ember.opacity(0.35 + 0.45 * s), lineWidth: 1).frame(width: 11, height: 11).scaleEffect(0.9 + 0.12 * s)
        }
    }
}

/// Claude and Codex side by side, reacting to the stage: alternate pulse while answering, turn toward each other while judging,
/// the acting model glows while drafting/reviewing. Logos are only dimmed, never recoloured.
private struct DualMarks: View {
    let stage: DualStage
    let reduce: Bool
    private let size: CGFloat = 16

    private var acting: Backend? {
        switch stage { case .drafting(let b), .reviewing(let b): b; default: nil }
    }
    private var judging: Bool { stage == .judging }

    var body: some View {
        TimelineView(.animation(paused: reduce || stage != .answering)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate * 2 * .pi / 1.6
            let c = (sin(t) + 1) / 2, x = 1 - c            // alternate: when one is up the other is down
            HStack(spacing: judging ? 2 : 6) {
                mark(.claude, pulse: stage == .answering && !reduce ? c : 0.5, tilt: judging ? 10 : 0)
                mark(.codex, pulse: stage == .answering && !reduce ? x : 0.5, tilt: judging ? -10 : 0)
            }
        }
        .animation(reduce ? .easeOut(duration: 0.15) : .spring(duration: 0.4, bounce: 0.3), value: stage)
        .frame(width: 2 * size + 6)
    }

    private func mark(_ b: Backend, pulse: Double, tilt: Double) -> some View {
        let lit = acting == b, dimmed = acting != nil && !lit
        let base = stage == .answering ? 0.55 + 0.45 * pulse : 1
        return ModelMark(backend: b, size: size, active: !dimmed)
            .opacity(dimmed ? 1 : base)
            .scaleEffect(reduce ? 1 : (lit ? 1.15 : stage == .answering ? 0.94 + 0.1 * pulse : 1))
            .rotationEffect(.degrees(reduce ? 0 : tilt))
            .background(Circle().fill(Ink.ember.opacity(lit ? 0.35 : 0)).blur(radius: 6).scaleEffect(1.5))   // glow, behind the logo
    }
}

/// One quiet line under a finished Both answer: who won, in the judges' words.
struct DualVerdictLine: View {
    let verdict: String
    let winner: Backend?
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var shown = false

    var body: some View {
        HStack(spacing: 6) {
            if let w = winner { ModelMark(backend: w, size: 12, active: true) }
            Text(verdict).font(.system(size: 11)).foregroundStyle(Ink.dim).lineLimit(2)
        }
        .opacity(shown ? 1 : 0)
        .offset(y: shown || reduce ? 0 : 6)
        .onAppear { withAnimation(reduce ? .easeOut(duration: 0.2) : .spring(duration: 0.45, bounce: 0.15).delay(0.1)) { shown = true } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Verdict: \(verdict)")
    }
}

#if DEBUG
#Preview("Dual stages") {
    VStack(alignment: .leading, spacing: 16) {
        DualStageView(stage: .answering)
        DualStageView(stage: .judging)
        DualStageView(stage: .drafting(by: .claude))
        DualStageView(stage: .reviewing(by: .codex))
        DualVerdictLine(verdict: "Both preferred Claude's answer; Codex's points folded in. Reviewed by Codex.", winner: .claude)
    }
    .padding(30).frame(width: 560).background(.black)
}
#endif
