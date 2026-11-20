import SwiftUI

/// Boxes with short labels drawn over the real screen. Click-through; gone on `clear()` or after a minute.
@MainActor
enum MarkOverlay {
    private static var panel: NSPanel?
    private static var timer: Task<Void, Never>?

    /// `marks` are in AppKit global points (see `ScreenMarks.toScreen`); `frame` is the display they are on.
    static func show(_ marks: [ScreenMarks.Mark], on frame: CGRect) {
        guard !marks.isEmpty else { clear(); return }
        let p = panel ?? { let n = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            n.level = .statusBar        // above apps and the menu bar, which is where half the questions are about
            n.isOpaque = false; n.backgroundColor = .clear; n.hasShadow = false; n.ignoresMouseEvents = true
            n.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel = n; return n }()
        p.setFrame(frame, display: false)
        p.contentView = NSHostingView(rootView: MarkLayer(marks: marks, frame: frame))
        p.alphaValue = 1; p.orderFrontRegardless()
        timer?.cancel()
        timer = Task { try? await Task.sleep(for: .seconds(60)); if !Task.isCancelled { clear() } }
    }

    static func clear() {
        timer?.cancel(); timer = nil
        guard let p = panel else { return }
        panel = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; p.animator().alphaValue = 0 }, completionHandler: { MainActor.assumeIsolated { p.orderOut(nil) } })
    }
}

private struct MarkLayer: View {
    let marks: [ScreenMarks.Mark]
    let frame: CGRect
    @State private var shown = false
    @State private var pulse = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(marks.enumerated()), id: \.offset) { i, m in
                let x = m.rect.minX - frame.minX, y = frame.maxY - m.rect.maxY      // back to top-left origin inside the panel
                RoundedRectangle(cornerRadius: 6).fill(Ink.ember.opacity(0.14))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Ink.ember, lineWidth: 2.5))
                    .frame(width: m.rect.width, height: m.rect.height)
                    .scaleEffect(pulse ? 1 : 1.06)
                    .offset(x: x, y: y)
                Text(marks.count > 1 ? "\(i + 1)  \(m.label)" : m.label)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.black)
                    .padding(.horizontal, 8).padding(.vertical, 3).background(Ink.ember, in: Capsule())
                    .offset(x: x, y: y > 28 ? y - 26 : y + m.rect.height + 4)
            }
        }
        .frame(width: frame.width, height: frame.height, alignment: .topLeading)
        .opacity(shown ? 1 : 0)
        .onAppear { withAnimation(.easeOut(duration: 0.25)) { shown = true }; withAnimation(.spring(duration: 0.5, bounce: 0.4)) { pulse = true } }
    }
}
