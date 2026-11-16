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

    static let width: CGFloat = 480
    static let replyWidth: CGFloat = 600
    static let notesWidth: CGFloat = 600
    static func notesHeight(_ notch: CGSize) -> CGFloat { notch.height + NotchWindow.maxBody + 210 }
    static func replyHeight(_ notch: CGSize) -> CGFloat { notch.height + 6 + 38 + ReplyPanel.bodyH + 22 + 44 + 54 + 8 }
    private static let bodyH: CGFloat = 64, actionsH: CGFloat = 40
    static func height(_ notch: CGSize) -> CGFloat { notch.height + 6 + bodyH + actionsH + 8 }

    var body: some View {
        if let a = c.current {
            let open = c.presenting, notes = c.notesOpen, reply = c.replyOpen || notes
            let w = notes ? Self.notesWidth : reply ? Self.replyWidth : Self.width, h = notes ? Self.notesHeight(notch) : reply ? Self.replyHeight(notch) : Self.height(notch)
            let mode = open ? (reply ? 2 : 1) : 0            // the animation is picked by where it is going: opening, growing into the reply, or folding away
            let shape = UnevenRoundedRectangle(bottomLeadingRadius: open ? 26 : 10, bottomTrailingRadius: open ? 26 : 10)
            shape.fill(.black)
                .frame(width: open ? w : notch.width)
                .animation(reduce ? .easeOut(duration: 0.2) : open ? .spring(duration: 0.55, bounce: reply ? 0.12 : 0.28) : .smooth(duration: 0.4).delay(0.08), value: mode)      // opens wide first; closes narrow last
                .frame(height: open ? h : notch.height)
                .animation(reduce ? .easeOut(duration: 0.2) : open ? .spring(duration: 0.6, bounce: reply ? 0.1 : 0.2).delay(reply ? 0 : 0.07) : .smooth(duration: 0.4), value: mode)         // opens tall second; folds up first, with no bounce
                .overlay(alignment: .top) { if notes { WhatsNewPanel(c: c, notch: notch) } else if reply, let s = c.session { ReplyPanel(c: c, s: s, notch: notch) } else { content(a) } }
                .overlay { rimTimer }
                .clipShape(shape)
                .allowsHitTesting(open)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("\(a.sender) on \(AddonMark.name(a.addon)): \(a.headline). \(a.reason)")
        }
    }

    // MARK: pieces

    private func content(_ a: AddonAlert) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                HStack(spacing: 7) {
                    AddonMark(addon: a.addon, size: 17)
                    Text(a.addon == "phone" ? "iPhone" : a.addon == "mac" ? a.sender : c.accounts.count > 1 && a.kind == nil ? (a.account.map { String($0.split(separator: "@").first ?? "") } ?? AddonMark.name(a.addon)) : AddonMark.name(a.addon))   // with several accounts, say which
                        .font(.system(size: 11, weight: .medium)).tracking(0.3).foregroundStyle(Ink.dim).lineLimit(1)
                    if c.queued > 0 { Text("+\(c.queued)").font(.system(size: 11, weight: .medium)).foregroundStyle(Ink.ember).help("\(c.queued) more waiting") }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 26)
                Color.clear.frame(width: notch.width)
                Text(a.sender).font(.system(size: 11, weight: .medium)).tracking(0.3).foregroundStyle(Ink.text.opacity(0.75)).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 26)
            }
            .frame(height: notch.height)
            .reveal(c.shown, 0, reduce)

            VStack(alignment: .leading, spacing: 5) {
                Text(a.headline).font(.system(size: 16, weight: .semibold)).foregroundStyle(Ink.text).lineLimit(1)
                    .reveal(c.shown, 0.07, reduce)
                Text(a.reason).font(.system(size: 13)).foregroundStyle(Ink.dim).lineLimit(2).fixedSize(horizontal: false, vertical: true)
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
        let update = c.current?.kind == "update", access = c.current?.kind == "phone-access", reconnect = c.current?.kind == "reconnect" || access, phone = c.current?.addon == "phone" || c.current?.addon == "mac"
        return HStack(spacing: 22) {
            if c.current?.kind == "reminder" {
                Button { c.open() } label: {
                    HStack(spacing: 6) { Text("Done").font(.system(size: 15, weight: .semibold)).foregroundStyle(Ink.ember); key("⌥↩") }.contentShape(Rectangle())
                }
                Button { c.dismiss() } label: {
                    HStack(spacing: 6) { Text("In 10 min").font(.system(size: 14)).foregroundStyle(Ink.dim); key("⌥esc") }.contentShape(Rectangle())
                }
                Spacer(minLength: 8)
            } else if update {
                Button { c.openNotes() } label: {
                    HStack(spacing: 6) { Text("What's new").font(.system(size: 15, weight: .semibold)).foregroundStyle(Ink.ember); key("⌥N") }.contentShape(Rectangle())
                }
                Button { c.open() } label: {
                    HStack(spacing: 6) { Text(AppUpdater.shared.readyVersion != nil ? "Restart" : "Update").font(.system(size: 15, weight: .semibold)).foregroundStyle(Ink.text.opacity(0.9)); key("⌥↩") }.contentShape(Rectangle())
                }
                Button { c.dismiss() } label: {
                    HStack(spacing: 6) { Text("Later").font(.system(size: 14)).foregroundStyle(Ink.dim); key("⌥esc") }.contentShape(Rectangle())
                }
                Spacer(minLength: 8)
            } else if reconnect {
                Button { c.open() } label: {
                    HStack(spacing: 6) { Text(access ? "Open Settings" : "Reconnect").font(.system(size: 15, weight: .semibold)).foregroundStyle(Ink.ember); key("⌥↩") }.contentShape(Rectangle())
                }
                Button { c.dismiss() } label: {
                    HStack(spacing: 6) { Text("Later").font(.system(size: 14)).foregroundStyle(Ink.dim); key("⌥esc") }.contentShape(Rectangle())
                }
                Spacer(minLength: 8)
            } else {
            Button { c.open() } label: {
                HStack(spacing: 6) { Text(phone ? "Done" : "Open").font(.system(size: 15, weight: .semibold)).foregroundStyle(Ink.ember); key("⌥↩") }.contentShape(Rectangle())
            }
            if !phone { Button { c.startReply() } label: {
                HStack(spacing: 6) { Text("Reply").font(.system(size: 15, weight: .semibold)).foregroundStyle(Ink.text.opacity(0.9)); key("⌥R") }.contentShape(Rectangle())
            }
            .help("Draft a reply with an AI agent, or ask about this email") }
            Button { c.notImportant() } label: {
                HStack(spacing: 6) { Text("Not important").font(.system(size: 14)).foregroundStyle(Ink.dim); key("⌥⌫") }.contentShape(Rectangle())
            }
            .help(phone ? "Never show notifications from this app  ⌥⌫" : "Never show mail from this sender  ⌥⌫")
            Spacer(minLength: 8)
            key("⌥esc")
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 28)
        .frame(height: Self.actionsH)
        .background(Rectangle().fill(Ink.text.opacity(0.08)).frame(height: 1).padding(.horizontal, 26), alignment: .top)
    }

    /// The rim is the timer. The comet "loads" it (the lit line follows the comet round the pill), then it drains from the start
    /// back toward the end over `dwell`. A dim track stays behind so you can see what is left. Brighter while held.
    private var sealed: Bool { c.session?.outcome == .sent || c.session?.outcome == .saved }

    private var rimTimer: some View {
        ZStack {
            RimShape(from: 0, to: 1).stroke(Ink.ember.opacity(0.10), style: StrokeStyle(lineWidth: 1.25, lineCap: .round))
            RimShape(from: 1 - c.progress, to: loaded ? 1 : 0)
                .stroke(Ink.ember.opacity(c.hovering ? 0.9 : 0.55), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .animation(reduce ? .easeOut(duration: 0.2) : .timingCurve(0.33, 1, 0.68, 1, duration: 1.25), value: loaded)   // same ease as the comet
                .animation(.easeOut(duration: 0.2), value: c.hovering)
        }
        .overlay {
            // a reply has gone: the rim lights up behind the comet that runs it, the same ease as the arrival
            RimShape(from: 0, to: sealed ? 1 : 0)
                .stroke(Ink.ember.opacity(0.9), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .shadow(color: Ink.ember.opacity(sealed ? 0.5 : 0), radius: 5)
                .animation(reduce ? .easeOut(duration: 0.2) : .timingCurve(0.33, 1, 0.68, 1, duration: 1.1), value: sealed)
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
        return Comet.rim(r.insetBy(dx: 1, dy: 1)).trimmedPath(from: lo, to: hi)
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

/// The comet: a bright head with a tapering tail, drawn along the card's rim (down the left side, along the bottom, up the right).
/// One drawing routine for every use of it, so the arrival, the "sending" orbit and the "sent" seal are visibly the same light.
enum Comet {
    nonisolated static let tail = 0.34           // comet length as a fraction of the rim
    nonisolated static let slices = 36           // the tail is this many strokes, each dimmer and thinner than the last

    /// The rim as one open path, so trimming it gives constant speed: top-left, down, round the corner, along the bottom, round, up to top-right.
    nonisolated static func rim(_ r: CGRect, radius: CGFloat = 26) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY - radius))
        p.addArc(center: CGPoint(x: r.minX + radius, y: r.maxY - radius), radius: radius, startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true)
        p.addLine(to: CGPoint(x: r.maxX - radius, y: r.maxY))
        p.addArc(center: CGPoint(x: r.maxX - radius, y: r.maxY - radius), radius: radius, startAngle: .degrees(90), endAngle: .degrees(0), clockwise: true)
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        return p
    }

    /// white-hot at the head, ember, then deep ember at the tip of the tail
    nonisolated static func color(_ f: Double) -> Color {
        f < 0.18 ? Color(red: 1.0, green: 0.95, blue: 0.85) : f < 0.55 ? Ink.ember : Ink.emberDeep
    }

    /// `head` runs from 0 (not yet on the rim) to 1 + tail (fully gone); `fade` dims the whole comet.
    nonisolated static func draw(_ ctx: inout GraphicsContext, size: CGSize, head: Double, fade: Double = 1) {
        let path = rim(CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1))
        func strokes(_ c: inout GraphicsContext, width: CGFloat, opacity: Double) {
            for k in 0..<slices {
                let f0 = Double(k) / Double(slices), f1 = Double(k + 1) / Double(slices)
                let hi = min(head - tail * f0, 1), lo = max(head - tail * f1, 0)
                guard hi > lo else { continue }
                c.stroke(path.trimmedPath(from: lo, to: hi), with: .color(color(f0).opacity(pow(1 - f0, 2.2) * opacity * fade)),
                         style: StrokeStyle(lineWidth: width * (1 - 0.55 * f0), lineCap: .round))
            }
        }
        ctx.drawLayer { l in l.addFilter(.blur(radius: 4)); strokes(&l, width: 4, opacity: 0.55) }      // light bleeding off the edge
        strokes(&ctx, width: 1.8, opacity: 1)                                                            // the crisp line
    }
}

/// One lap of the comet each time `tick` changes: the arrival of a card, and the seal when a reply has gone. Sized to the pill it runs round.
struct NotchStreak: View {
    let tick: Int
    let size: CGSize
    var lap: Double = 1.25
    @Environment(\.accessibilityReduceMotion) private var reduce

    private struct Frame { var p = 0.0 }    // 0 → 1 progress, mapped to the head position by an ease-out

    var body: some View {
        KeyframeAnimator(initialValue: Frame(), trigger: tick) { v in
            Canvas { ctx, sz in
                guard v.p > 0, v.p < 1 else { return }
                let head = (1 - pow(1 - v.p, 3)) * (1 + Comet.tail)                       // fast out of the corner, settling as it leaves
                Comet.draw(&ctx, size: sz, head: head, fade: min(v.p / 0.08, 1) * min((1 - v.p) / 0.12, 1))     // no pop at either end
            }
        } keyframes: { _ in
            KeyframeTrack(\.p) { LinearKeyframe(0, duration: 0.001); LinearKeyframe(1, duration: reduce ? 0.001 : lap) }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }
}

/// While a reply is on its way out the comet keeps circling, so the rim says "working" until Gmail answers.
struct RimOrbit: View {
    let size: CGSize
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !active || reduce)) { tl in
            Canvas { ctx, sz in
                guard active, !reduce else { return }
                let p = (tl.date.timeIntervalSinceReferenceDate / 1.15).truncatingRemainder(dividingBy: 1)
                let eased = p < 0.5 ? 2 * p * p : 1 - pow(-2 * p + 2, 2) / 2                      // each lap accelerates round the corners and eases at the top
                Comet.draw(&ctx, size: sz, head: eased * (1 + Comet.tail))
            }
        }
        .frame(width: size.width, height: size.height)
        .opacity(active ? 1 : 0).animation(.easeOut(duration: 0.2), value: active)
        .allowsHitTesting(false)
    }
}
