import SwiftUI

/// What an add-on says at the notch. One choreographed arrival, then quiet:
///   1. a spark of ember runs along the hardware notch's lower edge (the only "ping"; no sound, nothing bounces),
///   2. the notch widens, then drops, like the island it already is,
///   3. the words come out of the blur one line at a time: who, what, why, then the two things you can do,
///   4. an ember hairline drains along the bottom for 12 seconds; resting the pointer on the card holds it,
///   5. the words leave first, the shell folds back into the hardware.
struct AlertView: View {
    var c: AddonCenter
    let notch: CGSize
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var loaded = false

    static let width: CGFloat = 448
    private static let bodyH: CGFloat = 64, actionsH: CGFloat = 40
    static func height(_ notch: CGSize) -> CGFloat { notch.height + 6 + bodyH + actionsH + 8 }

    var body: some View {
        if let a = c.current {
            let open = c.presenting
            let shape = UnevenRoundedRectangle(bottomLeadingRadius: open ? 26 : 10, bottomTrailingRadius: open ? 26 : 10)
            shape.fill(.black)
                .frame(width: open ? Self.width : notch.width)
                .animation(reduce ? .easeOut(duration: 0.2) : open ? .spring(duration: 0.55, bounce: 0.28) : .smooth(duration: 0.4).delay(0.08), value: open)      // opens wide first; closes narrow last
                .frame(height: open ? Self.height(notch) : notch.height)
                .animation(reduce ? .easeOut(duration: 0.2) : open ? .spring(duration: 0.6, bounce: 0.2).delay(0.07) : .smooth(duration: 0.4), value: open)         // opens tall second; folds up first, with no bounce
                .overlay(alignment: .top) { content(a) }
                .overlay { rimTimer }
                .clipShape(shape)
                .allowsHitTesting(open)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("\(a.sender) on Gmail: \(a.headline). \(a.reason)")
        }
    }

    // MARK: pieces

    private func content(_ a: AddonAlert) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                HStack(spacing: 7) {
                    AddonMark(addon: a.addon, size: 17)
                    Text(c.accounts.count > 1 ? (a.account.map { String($0.split(separator: "@").first ?? "") } ?? "Gmail") : "Gmail")   // with several accounts, say which
                        .font(.system(size: 11, weight: .medium)).tracking(0.3).foregroundStyle(Ink.dim).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 26)
                Color.clear.frame(width: notch.width)
                Text(a.sender).font(.system(size: 11, weight: .medium)).tracking(0.3).foregroundStyle(Ink.text.opacity(0.75)).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 26)
            }
            .frame(height: notch.height)
            .reveal(c.shown, 0, reduce)

            VStack(alignment: .leading, spacing: 5) {
                Text(a.headline).font(.system(size: 17, weight: .semibold, design: .serif)).foregroundStyle(Ink.text).lineLimit(1)
                    .reveal(c.shown, 0.07, reduce)
                Text(a.reason).font(.system(size: 13.5, design: .serif)).italic().foregroundStyle(Ink.dim).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .reveal(c.shown, 0.15, reduce)
            }
            .frame(maxWidth: .infinity, minHeight: Self.bodyH, alignment: .topLeading)
            .padding(.horizontal, 28).padding(.top, 6)
            .contentShape(Rectangle()).onTapGesture { c.open() }

            actions.reveal(c.shown, 0.24, reduce)
        }
        .frame(width: Self.width)
    }

    private func key(_ k: String) -> some View {
        Text(k).font(.system(size: 11, weight: .medium)).foregroundStyle(Ink.text.opacity(0.6))
            .padding(.horizontal, 5).padding(.vertical, 1.5).overlay(RoundedRectangle(cornerRadius: 4).stroke(Ink.text.opacity(0.22), lineWidth: 0.75))
    }

    private var actions: some View {
        HStack(spacing: 22) {
            Button { c.open() } label: {
                HStack(spacing: 6) { Text("Open").font(.system(size: 15, weight: .semibold, design: .serif)).foregroundStyle(Ink.ember); key("⌥↩") }.contentShape(Rectangle())
            }
            Button { c.notImportant() } label: {
                HStack(spacing: 6) { Text("Not important").font(.system(size: 14, design: .serif)).foregroundStyle(Ink.dim); key("⌥⌫") }.contentShape(Rectangle())
            }
            .help("Never show mail from this sender  ⌥⌫")
            Spacer(minLength: 8)
            key("⌥esc")
            if c.queued > 0 { Text("+\(c.queued) more").font(.system(size: 12, design: .serif)).italic().foregroundStyle(Ink.dim) }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 28)
        .frame(height: Self.actionsH)
        .background(Rectangle().fill(Ink.text.opacity(0.08)).frame(height: 1).padding(.horizontal, 26), alignment: .top)
    }

    /// The rim is the timer. The comet "loads" it (the lit line follows the comet round the pill), then it drains from the start
    /// back toward the end over `dwell`. A dim track stays behind so you can see what is left. Brighter while held.
    private var rimTimer: some View {
        ZStack {
            RimShape(from: 0, to: 1).stroke(Ink.ember.opacity(0.10), style: StrokeStyle(lineWidth: 1.25, lineCap: .round))
            RimShape(from: 1 - c.progress, to: loaded ? 1 : 0)
                .stroke(Ink.ember.opacity(c.hovering ? 0.9 : 0.55), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .animation(reduce ? .easeOut(duration: 0.2) : .timingCurve(0.33, 1, 0.68, 1, duration: 1.25), value: loaded)   // same ease as the comet
                .animation(.easeOut(duration: 0.2), value: c.hovering)
        }
        .opacity(c.shown ? 1 : 0).animation(.easeOut(duration: 0.3), value: c.shown)
        .onChange(of: c.streakTick) { loaded = true }
        .onChange(of: c.current?.id) { loaded = false }
        .allowsHitTesting(false)
    }
}

/// The U-shaped rim (left side, bottom, right side) as an animatable, trimmable shape.
private struct RimShape: Shape {
    var from: Double, to: Double
    var animatableData: AnimatablePair<Double, Double> { get { .init(from, to) } set { from = newValue.first; to = newValue.second } }
    func path(in r: CGRect) -> Path {
        let lo = min(max(from, 0), 1), hi = min(max(to, 0), 1)
        guard hi > lo else { return Path() }
        return NotchStreak.rim(r.insetBy(dx: 1, dy: 1)).trimmedPath(from: lo, to: hi)
    }
}

/// Words arrive out of a blur, a few points low, in sequence; they leave all at once and fast.
private struct Reveal: ViewModifier {
    let on: Bool, delay: Double, reduce: Bool
    func body(content: Content) -> some View {
        content.opacity(on ? 1 : 0).blur(radius: on || reduce ? 0 : 7).offset(y: on || reduce ? 0 : 5)
            .animation(reduce ? .easeOut(duration: 0.15) : on ? .easeOut(duration: 0.45).delay(delay) : .easeIn(duration: 0.2).delay(0.12 - min(delay, 0.12) / 2), value: on)
    }
}
private extension View { func reveal(_ on: Bool, _ delay: Double, _ reduce: Bool) -> some View { modifier(Reveal(on: on, delay: delay, reduce: reduce)) } }

/// The arrival: once the shell has opened, a single comet of light travels its whole rim (down the left side, along the bottom, up the
/// right) with a tapering tail, then is gone; only the faint lit edge stays. Drawn on the pill's final outline, so it starts as the words resolve.
struct NotchStreak: View {
    let tick: Int
    let notch: CGSize
    @Environment(\.accessibilityReduceMotion) private var reduce

    private static let tail = 0.34          // comet length as a fraction of the rim
    private static let slices = 36          // the tail is this many strokes, each dimmer and thinner than the last

    private struct Frame { var p = 0.0 }    // 0 → 1 progress, mapped to head position by an ease-out

    /// The rim as one open path, so trimming it gives constant speed: top-left, down, round the corner, along the bottom, round, up to top-right.
    static func rim(_ r: CGRect, radius: CGFloat = 26) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY - radius))
        p.addArc(center: CGPoint(x: r.minX + radius, y: r.maxY - radius), radius: radius, startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true)
        p.addLine(to: CGPoint(x: r.maxX - radius, y: r.maxY))
        p.addArc(center: CGPoint(x: r.maxX - radius, y: r.maxY - radius), radius: radius, startAngle: .degrees(90), endAngle: .degrees(0), clockwise: true)
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        return p
    }

    /// white-hot at the head → ember → deep ember at the tip of the tail
    private static func color(_ f: Double) -> Color {
        f < 0.18 ? Color(red: 1.0, green: 0.95, blue: 0.85)
                 : f < 0.55 ? Ink.ember : Ink.emberDeep
    }

    var body: some View {
        KeyframeAnimator(initialValue: Frame(), trigger: tick) { v in
            Canvas { ctx, size in
                guard v.p > 0, v.p < 1 else { return }
                let path = Self.rim(CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1))
                let head = (1 - pow(1 - v.p, 3)) * (1 + Self.tail)          // fast out of the corner, settling as it leaves
                let fade = min(v.p / 0.08, 1) * min((1 - v.p) / 0.12, 1)     // no pop at either end
                func strokes(_ c: inout GraphicsContext, width: CGFloat, opacity: Double) {
                    for k in 0..<Self.slices {
                        let f0 = Double(k) / Double(Self.slices), f1 = Double(k + 1) / Double(Self.slices)
                        let hi = min(head - Self.tail * f0, 1), lo = max(head - Self.tail * f1, 0)
                        guard hi > lo else { continue }
                        c.stroke(path.trimmedPath(from: lo, to: hi), with: .color(Self.color(f0).opacity(pow(1 - f0, 2.2) * opacity * fade)),
                                 style: StrokeStyle(lineWidth: width * (1 - 0.55 * f0), lineCap: .round))
                    }
                }
                ctx.drawLayer { l in l.addFilter(.blur(radius: 4)); strokes(&l, width: 4, opacity: 0.55) }   // light bleeding off the edge
                strokes(&ctx, width: 1.8, opacity: 1)                                                         // the crisp line
            }
        } keyframes: { _ in
            KeyframeTrack(\.p) { LinearKeyframe(0, duration: 0.001); LinearKeyframe(1, duration: reduce ? 0.001 : 1.25) }
        }
        .frame(width: AlertView.width, height: AlertView.height(notch))
        .allowsHitTesting(false)
    }
}
