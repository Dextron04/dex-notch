import SwiftUI
import Observation

// The notch reaching out and pointing. One archetype throughout: the notch's own spring (0.45s, a little bounce) for things that arrive,
// a fast ease-out for things that leave. Reduce Motion keeps every state change but drops the travel: plain fades, no breathing.

extension Backend {
    /// The answering model's colour on the screen: Claude's orange, Codex's white, the local model's ember.
    var accent: Color { switch self { case .claude: Color(red: 0.851, green: 0.467, blue: 0.341); case .codex: .white; case .gemma, .both: Ink.ember } }
}

@Observable @MainActor
final class MarkState { var marks: [ScreenMarks.Mark] = []; var accent = Ink.ember; var bubbles = false }

/// Boxes with short labels drawn over the real screen. Click-through; gone on `clear()` or after a minute.
@MainActor
enum MarkOverlay {
    private static var panel: NSPanel?
    private static var state = MarkState()
    private static var timer: Task<Void, Never>?
    static var reduce: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private static func makePanel(_ frame: CGRect) -> NSPanel {
        let n = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        n.level = .statusBar        // above apps and the menu bar, which is where half the questions are about
        n.isOpaque = false; n.backgroundColor = .clear; n.hasShadow = false; n.ignoresMouseEvents = true
        n.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        return n
    }

    /// `marks` are in AppKit global points (see `ScreenMarks.toScreen`); `frame` is the display they are on. Calling it again with more marks
    /// only animates the new ones in.
    static func show(_ marks: [ScreenMarks.Mark], on frame: CGRect, accent: Color, bubbles: Bool = false) {
        guard !marks.isEmpty else { clear(); return }
        if panel == nil {
            state = MarkState()
            let p = makePanel(frame)
            let visible = NSScreen.screens.first { $0.frame == frame }?.visibleFrame ?? frame      // bubbles stay out of the menu bar and the Dock
            p.contentView = NSHostingView(rootView: MarkLayer(state: state, frame: frame, visible: visible, reduce: reduce))
            panel = p
        }
        panel?.setFrame(frame, display: false)
        state.accent = accent; state.marks = marks; state.bubbles = bubbles
        panel?.alphaValue = 1; panel?.orderFrontRegardless()
        timer?.cancel()
        timer = Task { try? await Task.sleep(for: .seconds(60)); if !Task.isCancelled { clear() } }
    }

    /// Fast ease-out, a touch smaller as it goes: leaving is quicker than arriving.
    static func clear() {
        timer?.cancel(); timer = nil
        guard let p = panel else { return }
        panel = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; $0.timingFunction = CAMediaTimingFunction(name: .easeIn); p.animator().alphaValue = 0 },
                                             completionHandler: { MainActor.assumeIsolated { p.orderOut(nil) } })
    }

    /// The shutter: an ember glow around the captured display's edge, in 80ms and out in 240ms. Shown after the capture, and our windows are excluded from it anyway.
    static func flash(on frame: CGRect) {
        let p = makePanel(frame)
        p.contentView = NSHostingView(rootView: ShutterFlash(reduce: reduce))
        p.orderFrontRegardless()
        Task { try? await Task.sleep(for: .milliseconds(500)); p.orderOut(nil) }
    }
}

private struct ShutterFlash: View {
    let reduce: Bool
    @State private var on = false
    var body: some View {
        Group {
            if reduce { Rectangle().fill(Color.white.opacity(0.08)) }
            else { Rectangle().strokeBorder(Ink.ember, lineWidth: 10).blur(radius: 9).overlay(Rectangle().strokeBorder(Ink.ember.opacity(0.7), lineWidth: 2)) }
        }
        .opacity(on ? 1 : 0).ignoresSafeArea()
        .task {
            withAnimation(.easeOut(duration: 0.08)) { on = true }
            try? await Task.sleep(for: .milliseconds(80))
            withAnimation(.easeIn(duration: 0.24)) { on = false }
        }
    }
}

private struct MarkLayer: View {
    let state: MarkState
    let frame: CGRect
    let visible: CGRect
    let reduce: Bool
    @State private var dim = false

    /// Local, top-left origin coordinates inside the panel.
    private func local(_ r: CGRect) -> CGRect { CGRect(x: r.minX - frame.minX, y: frame.maxY - r.maxY, width: r.width, height: r.height) }
    /// Where the bubbles go: the model's pick when it is clear, the app's own choice otherwise (see `ScreenMarks.placeBubbles`). The notch's strip is off limits.
    private func bubbleRects(_ rects: [CGRect]) -> [CGRect] {
        let wanted = state.marks.map { m in m.bubble.map { CGPoint(x: $0.x - frame.minX, y: frame.maxY - $0.y) } }      // bubble anchors arrive as AppKit global points
        let notch = CGRect(x: frame.width / 2 - 150, y: 0, width: 300, height: 50)
        return ScreenMarks.placeBubbles(boxes: rects, wanted: wanted, sizes: state.marks.map { ScreenMarks.bubbleSize($0.label) }, bounds: local(visible), avoid: [notch])
    }
    /// Reading order decides who appears first; the numbers stay as the model wrote them, so they match the badges in the answer.
    private var order: [Int: Int] {
        let s = state.marks.indices.sorted { let a = state.marks[$0].rect, b = state.marks[$1].rect; return (-a.maxY, a.minX) < (-b.maxY, b.minX) }
        return Dictionary(uniqueKeysWithValues: s.enumerated().map { ($1, $0) })
    }

    var body: some View {
        let rects = state.marks.map { local($0.rect) }, rank = order
        let notes = state.bubbles ? bubbleRects(rects) : []
        ZStack(alignment: .topLeading) {
            // a quiet dim everywhere except the marked spots, so the eye lands there; click-through like the rest
            Rectangle().fill(.black.opacity(dim ? 0.2 : 0))
                .mask(Rectangle().overlay(alignment: .topLeading) {
                    ForEach(Array(rects.enumerated()), id: \.offset) { _, r in
                        RoundedRectangle(cornerRadius: 8).frame(width: r.width + 12, height: r.height + 12).offset(x: r.minX - 6, y: r.minY - 6).blendMode(.destinationOut)
                    }
                }.compositingGroup())
            ForEach(Array(rects.enumerated()), id: \.offset) { i, r in
                MarkBox(n: i + 1, rect: r, accent: state.accent, delay: Double(min(rank[i] ?? 0, 5)) * 0.07, reduce: reduce)
            }
            ForEach(Array(notes.enumerated()), id: \.offset) { i, b in
                Bubble(n: i + 1, note: state.marks[i].label, rect: b, box: rects[i], accent: state.accent, delay: 0.15 + Double(min(rank[i] ?? 0, 5)) * 0.08, reduce: reduce)
            }
        }
        .frame(width: frame.width, height: frame.height, alignment: .topLeading)
        .onAppear { withAnimation(.easeOut(duration: 0.35)) { dim = true } }
    }
}

private struct MarkBox: View {
    let n: Int, rect: CGRect, accent: Color, delay: Double, reduce: Bool
    @State private var drawn = false
    @State private var landed = false
    @State private var glow = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8).fill(accent.opacity(landed ? 0.1 : 0))
            RoundedRectangle(cornerRadius: 8).trim(from: 0, to: reduce || drawn ? 1 : 0).stroke(accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .opacity(drawn ? 1 : 0)
                .shadow(color: accent.opacity(glow ? 0.6 : 0.15), radius: glow ? 11 : 3)      // ambient: breathes while it is up
        }
        .frame(width: rect.width, height: rect.height).offset(x: rect.minX, y: rect.minY)
        badge.offset(x: rect.minX - 9, y: rect.minY - 9)
    }

    private var badge: some View {
        Text("\(n)").font(.system(size: 11, weight: .bold)).foregroundStyle(.black).frame(width: 20, height: 20).background(accent, in: Circle())
            .overlay(Circle().stroke(.black.opacity(0.5), lineWidth: 1))
            .scaleEffect(reduce ? 1 : landed ? 1 : 0.55).opacity(landed ? 1 : 0)
            .onAppear {
                withAnimation(.easeOut(duration: reduce ? 0.2 : 0.38).delay(delay)) { drawn = true }               // stroke draws on…
                withAnimation(reduce ? .easeOut(duration: 0.2).delay(delay) : .spring(duration: 0.45, bounce: 0.3).delay(delay + 0.22)) { landed = true }   // …then the badge springs in
                if !reduce { withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true).delay(delay + 0.8)) { glow = true } }
            }
    }
}

/// The explanation, as a speech bubble in empty space with a thin line to its box. Solid, so it reads on light and dark pages alike.
private struct Bubble: View {
    let n: Int, note: String, rect: CGRect, box: CGRect, accent: Color, delay: Double, reduce: Bool
    @State private var on = false

    private func nearest(_ p: CGPoint, in r: CGRect) -> CGPoint { CGPoint(x: min(max(p.x, r.minX), r.maxX), y: min(max(p.y, r.minY), r.maxY)) }

    var body: some View {
        let a = nearest(CGPoint(x: box.midX, y: box.midY), in: rect), b = nearest(a, in: box)
        ZStack(alignment: .topLeading) {
            Path { p in p.move(to: a); p.addLine(to: b) }.stroke(accent, style: StrokeStyle(lineWidth: 1.5, lineCap: .round)).opacity(on ? 0.9 : 0)
            HStack(alignment: .top, spacing: 8) {
                Text("\(n)").font(.system(size: 11, weight: .bold)).foregroundStyle(.black).frame(width: 18, height: 18).background(accent, in: Circle())
                Text(note).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white).lineLimit(5).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(width: rect.width, height: rect.height, alignment: .topLeading)
            .background(Color(red: 0.07, green: 0.07, blue: 0.08), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(accent.opacity(0.85), lineWidth: 1.5))
            .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
            .scaleEffect(reduce ? 1 : on ? 1 : 0.85, anchor: UnitPoint(x: (a.x - rect.minX) / max(rect.width, 1), y: (a.y - rect.minY) / max(rect.height, 1)))
            .offset(x: rect.minX, y: rect.minY).opacity(on ? 1 : 0)
        }
        .onAppear { withAnimation(reduce ? .easeOut(duration: 0.2).delay(delay) : .spring(duration: 0.45, bounce: 0.3).delay(delay)) { on = true } }
    }
}
