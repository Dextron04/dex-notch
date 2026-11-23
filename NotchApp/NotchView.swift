import SwiftUI

// Ink & ember: pure black that melts into the hardware notch, one warm accent, a quiet sans voice.
enum Ink {
    static let ember = Color(red: 1.00, green: 0.69, blue: 0.35)
    static let emberDeep = Color(red: 0.93, green: 0.42, blue: 0.18)
    static let text = Color(red: 0.95, green: 0.92, blue: 0.87)
    static let dim = Color(red: 0.95, green: 0.92, blue: 0.87).opacity(0.52)
}

private struct FieldHKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct HeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct NotchView: View {
    @Bindable var a: Assistant
    let notch: CGSize
    let panel: CGSize // root fills panel exactly so content never resizes it

    private let center = AddonCenter.shared
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var announced: Backend?        // the model the notch is naming right now (after a switch), then it goes away
    @State private var announceTick = 0
    @State private var announceTask: Task<Void, Never>?
    private static let announceHold: Double = 1.6
    @State private var contentH: CGFloat = 0
    @State private var showGlint = false
    @State private var fieldH: CGFloat = 0          // measured height of the prompt field: grows a line at a time, 1…4 lines
    @State private var keyTick = 0                  // bumps per typed keystroke: drives the edge glow
    @State private var keyPeak = 0.5                // glow strength for that keystroke, from typing rhythm
    @State private var lastKey = Date.distantPast
    @State private var lastTyped = ""               // what was in the field just before it was sent
    @State private var ghost: String?               // that text, lifting away as it becomes the question

    private let openW: CGFloat = 560
    private let inputH: CGFloat = 52
    private var rowH: CGFloat { max(inputH, fieldH.rounded(.up) + 28) }   // 14 pt above and below the text
    private var hasAnswer: Bool { !a.turns.isEmpty }
    private static let setupH: CGFloat = 168
    private var bodyH: CGFloat { a.needsSetup ? Self.setupH : hasAnswer ? min((contentH / 8).rounded(.up) * 8, NotchWindow.maxBody) : 0 }
    private var recallH: CGFloat { notch.height + 6 + RecallView.bodyHeight(a) + 12 }
    private var pillH: CGFloat {
        guard a.isOpen else { return notch.height }
        return a.mode == .recall ? recallH : notch.height + 6 + bodyH + rowH + 12
    }

    var body: some View {
        ZStack(alignment: .top) {
            // click on the empty panel area dismisses
            Color.clear.contentShape(Rectangle()).onTapGesture { a.close() }

            pill
            if !a.isOpen { AlertView(c: center, notch: notch) }
            if !a.isOpen {
                NotchStreak(tick: center.streakTick, size: CGSize(width: AlertView.width, height: AlertView.height(notch)))      // a card arrives
                let reply = CGSize(width: AlertView.replyWidth, height: AlertView.replyHeight(notch))
                RimOrbit(size: reply, active: center.replyOpen && center.session?.outcome == .sending)                           // a reply is leaving
                NotchStreak(tick: center.sealTick, size: reply, lap: 1.1)                                                        // …and it has gone
            }
        }
        .frame(width: panel.width, height: panel.height, alignment: .top)
        .onKeyPress(.escape) { if center.notesOpen { center.closeNotes() } else if center.replyOpen { center.collapseReply() } else { a.close() }; return .handled }
        .onChange(of: a.isOpen) { if a.isOpen { center.assistantOpened() } else { center.assistantClosed(); announceTask?.cancel(); announced = nil } }
        .onChange(of: a.backend) { focused = true; announce() }
        .onChange(of: a.draft) { typed() }
        .onChange(of: a.work) { announce() }
        .onChange(of: a.sentTick) {
            showGlint = true
            if !reduce, !lastTyped.isEmpty { ghost = lastTyped }
            Task { try? await Task.sleep(for: .milliseconds(450)); showGlint = false; ghost = nil }
        }
        // focus the moment the notch opens (no sleep: the first keystrokes land in the field); one runloop tick later in case SwiftUI hadn't built it yet
        .task(id: [a.isOpen ? 1 : 0, a.mode == .prompt ? 1 : 0]) { if a.isOpen && a.mode == .prompt { focused = true; await Task.yield(); focused = true } } // also when switching recall → prompt while open
    }

    private var pill: some View {
        UnevenRoundedRectangle(bottomLeadingRadius: a.isOpen ? 26 : 10, bottomTrailingRadius: a.isOpen ? 26 : 10)
            .fill(.black)
            .frame(width: a.isOpen ? openW : notch.width, height: pillH)
            .overlay(alignment: .top) { content }
            .overlay(alignment: .bottom) {
                ZStack(alignment: .bottom) {
                    if a.isOpen && a.mode == .prompt && a.busy && a.waiting { EmberSweep().transition(.opacity) }
                    if showGlint && !reduce { SendGlint() }      // a spoken question leaving: one ember pass, then the thinking sweep takes over
                }
            }
            .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: a.isOpen ? 26 : 10, bottomTrailingRadius: a.isOpen ? 26 : 10))
            .animation(.spring(duration: 0.5, bounce: 0.22), value: a.isOpen)
            .animation(.smooth(duration: 0.28), value: pillH)
    }

    private var content: some View {
        VStack(spacing: 0) {
            wings.frame(height: notch.height).blur(radius: settle)
            if a.mode == .recall {
                RecallView(a: a).padding(.top, 6).blur(radius: settle)
            } else {
                if a.needsSetup { setupCard.frame(height: bodyH).padding(.top, 6).blur(radius: settle) }
                else if hasAnswer { transcript.frame(height: bodyH).padding(.top, 6).blur(radius: settle) }
                inputRow.padding(.top, hasAnswer || a.needsSetup ? 0 : 6)
            }
        }
        .frame(width: openW)
        // content arrives just after the shell starts opening (the input row never blurs, so it is typeable at once), leaves before it closes
        .opacity(a.isOpen ? 1 : 0)
        .animation(.easeOut(duration: a.isOpen ? 0.22 : 0.12).delay(a.isOpen ? 0.07 : 0), value: a.isOpen)
    }

    private var settle: CGFloat { a.isOpen || reduce ? 0 : 8 }

    // MARK: wings — status flanking the hardware notch

    private var wings: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                StatusDot(link: a.mode == .recall ? (a.snapshot.recorderOK ? .ready : .offline) : (a.backend == .gemma ? a.link : .ready), busy: a.busy || a.summarizing)
                Text(statusText).font(.system(size: 11, weight: .medium)).tracking(0.3).foregroundStyle(Ink.dim)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 26)

            Color.clear.frame(width: notch.width)

            HStack(spacing: 14) {
                if a.mode == .prompt && hasAnswer && !a.busy && a.error == nil { hint("⇧⌘C", "copy") }
                else if a.mode == .prompt && !hasAnswer && !a.busy && a.choices.count > 1 { hint("⇥", "model") }
                hint("esc", "close")
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 26)
        }
    }

    private var statusText: String {
        if a.mode == .recall { return a.snapshot.recorderOK ? "recorder · running" : "recorder · not running" }
        if let p = a.screenProblem { return p }
        if a.needsSetup { return "setup needed" }
        if a.backend == .both {
            guard a.busy else { return "both · judge mode" }
            return switch a.dualStage {
            case .judging: "both · judging"
            case .drafting(let b): "both · drafting (\(b.displayName))"
            case .reviewing(let b): "both · reviewing (\(b.displayName))"
            default: "both · answering"
            }
        }
        if a.backend != .gemma {
            return a.busy ? (a.toolNote.map { "\(a.backend.rawValue) · " + ($0.hasPrefix("looked") ? $0 : "using \($0)") } ?? "\(a.backend.rawValue) · thinking")
                          : (a.work ? "\(a.backend.rawValue)+ · \(AgentStream.folderLabel(a.folder))" : "\(a.backend.rawValue) · subscription")
        }
        if a.gemma == nil { return a.configProblem != nil ? "local model · fix settings.json" : "local model · not set up" }
        return switch a.link {
        case .ready: a.waiting ? "thinking" : "local · \(a.gemma?.host ?? "")"
        case .connecting: "connecting to \(a.gemma?.host ?? "gemma")…"
        case .offline: "offline"
        }
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(key).foregroundStyle(Ink.text.opacity(0.75))
            Text(label).foregroundStyle(Ink.dim)
        }
        .font(.system(size: 11, weight: .medium)).tracking(0.3)
    }

    // MARK: transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 10) {
                    if let q = a.question {
                        Text(q).font(.system(size: 13)).foregroundStyle(Ink.dim).lineLimit(2)
                    }
                    if let st = a.dualStage, a.busy {
                        DualStageView(stage: st).transition(.opacity.combined(with: .offset(y: -4)))
                    }
                    if let e = a.error {
                        Text(e).font(.system(size: 15)).foregroundStyle(Ink.emberDeep)
                    } else if !a.answer.isEmpty {
                        AnswerBody(text: a.answer, accent: a.backend.accent)
                        if !a.busy, let v = a.turns.last?.verdict { DualVerdictLine(verdict: v, winner: a.turns.last?.winner) }
                        if !a.recalled.isEmpty && !a.busy {
                            Text("from your vault · " + a.recalled.prefix(3).joined(separator: " · "))
                                .font(.system(size: 11)).foregroundStyle(Ink.dim).lineLimit(2)
                        }
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 30)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(reduce ? nil : .smooth(duration: 0.25), value: a.dualStage != nil && a.busy)
                .background(GeometryReader { Color.clear.preference(key: HeightKey.self, value: $0.size.height) })
            }
            .scrollIndicators(.never)
            .onPreferenceChange(HeightKey.self) { contentH = $0 }
            .onChange(of: a.answer) { proxy.scrollTo("end", anchor: .bottom) }
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.04),
                                         .init(color: .black, location: 0.94), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
        }
    }

    // MARK: input

    private var placeholder: String {
        a.listening ? "Listening…" : a.needsSetup ? "Install claude or codex to begin" : a.backend == .gemma ? (hasAnswer ? "Follow up…" : "Ask anything") : (a.work && !hasAnswer ? "Ask \(a.backend.rawValue) · ⌘F folder" : "Ask \(a.backend.rawValue)…")
    }

    /// Per typed keystroke: strength from rhythm (fast typing glows harder), then the edge glow plays once and dies. Nothing runs while idle.
    private func typed() {
        guard !a.draft.isEmpty else { return }
        lastTyped = a.draft
        guard !a.listening, !reduce else { return }
        let dt = Date().timeIntervalSince(lastKey); lastKey = Date()
        keyPeak = dt < 0.12 ? 1 : dt < 0.3 ? 0.7 : 0.45
        keyTick += 1
    }

    private var inputRow: some View {
        let ready = !a.draft.isEmpty || a.seeScreen
        return HStack(alignment: .bottom, spacing: 10) {
            TextField("", text: $a.draft, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .font(.system(size: 19))
                .foregroundStyle(a.listening ? Ink.text.opacity(0.85) : Ink.text)
                .tint(Ink.ember)
                .focused($focused)          // stays enabled while answering: draft the follow-up, Return waits
                .onKeyPress(.return, phases: .down) { k in
                    if k.modifiers.contains(.shift) { a.draft += "\n"; return .handled }   // ⇧↩ newline (⌥↩ is the field's own)
                    if k.modifiers.contains(.option) { return .ignored }
                    a.send(); return .handled                                                // send() ignores it while busy
                }
                .background(GeometryReader { Color.clear.preference(key: FieldHKey.self, value: $0.size.height) })
                .onPreferenceChange(FieldHKey.self) { if $0 > 0, $0 != fieldH { fieldH = $0 } }
                .overlay(alignment: .topLeading) {
                    ZStack(alignment: .topLeading) {
                        if a.draft.isEmpty {
                            Text(placeholder).font(.system(size: 19)).foregroundStyle(Ink.dim).lineLimit(1).id(placeholder).transition(.opacity)
                        }
                        if let g = ghost { GhostText(text: g) }
                    }
                    .animation(.easeOut(duration: 0.18), value: placeholder)
                    .allowsHitTesting(false)
                }
                .padding(.vertical, 14)
            HStack(spacing: 10) {
                if hasAnswer && !a.busy {
                    Button { a.newConversation() } label: {
                        Image(systemName: "square.and.pencil").font(.system(size: 12, weight: .regular)).foregroundStyle(Ink.dim).padding(6).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).help("New conversation  ⌘N").accessibilityLabel("New conversation")
                }
                if let b = announced {
                    ModelAnnounce(backend: b, work: a.work, hold: Self.announceHold, reduce: reduce).id(announceTick)
                        .transition(reduce ? .opacity : .modifier(active: Slide(x: 12, opacity: 0, blur: 5), identity: Slide(x: 0, opacity: 1, blur: 0)))
                }
                langChip
                eyeChip
                ZStack {
                    if a.listening {
                        Wave(level: a.voiceLevel, still: reduce, live: true).frame(width: 54, height: 20).transition(.opacity)
                    } else {
                        ReturnGlyph(ready: ready, busy: a.busy, reduce: reduce).transition(.opacity)
                    }
                }
                .animation(reduce ? .easeOut(duration: 0.15) : .smooth(duration: 0.25), value: a.listening)
            }
            .frame(height: 24)
            .padding(.bottom, 14)
        }
        .padding(.horizontal, 30)
        .frame(height: rowH)
        .background(
            // hairline, not a box
            Rectangle().fill(Ink.text.opacity(hasAnswer ? 0.08 : 0)).frame(height: 1).padding(.horizontal, 26),
            alignment: .top)
        .background(alignment: .bottom) { edgeGlow(on: !a.draft.isEmpty && !a.busy) }
        .background(Button("") { copy() }.keyboardShortcut("c", modifiers: [.command, .shift]).opacity(0).allowsHitTesting(false))
    }

    /// An ember line under the field: draws out from the centre when there is something to send, and flares a little with each key.
    private func edgeGlow(on: Bool) -> some View {
        Capsule()
            .fill(LinearGradient(colors: [.clear, Ink.ember, .clear], startPoint: .leading, endPoint: .trailing))
            .frame(height: 1.5)
            .padding(.horizontal, 30)
            .scaleEffect(x: on ? 1 : 0.2)
            .opacity(on ? 0.22 : 0)
            .keyframeAnimator(initialValue: 0.0, trigger: keyTick) { v, f in v.opacity(1).brightness(0).shadow(color: Ink.ember.opacity(f * 0.8), radius: 5).overlay { Capsule().fill(Ink.ember).frame(height: 1.5).padding(.horizontal, 30).opacity(f * 0.8) } } keyframes: { _ in
                LinearKeyframe(keyPeak, duration: 0.04)
                CubicKeyframe(0, duration: 0.26)
            }
            .padding(.bottom, 6)
            .animation(reduce ? .easeOut(duration: 0.15) : .spring(duration: 0.4, bounce: 0.15), value: on)
            .allowsHitTesting(false)
    }

    /// The voice language: "EN", "HI", "HG". Click cycles the quick-switch set. A fixed slot, so nothing beside it moves; blank with one language.
    private var langChip: some View {
        let show = VoiceLanguages.shared.selected.count >= 2 || a.listening
        return Button { Dictation.shared.cycleLanguage() } label: {
            Text(Dictation.shared.currentLanguageCode).font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(a.listening ? Ink.ember : Ink.dim)
                .frame(width: 26, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(show ? 1 : 0).allowsHitTesting(show && !a.listening)
        .help("Voice language · click to switch").accessibilityLabel("Voice language \(Dictation.shared.currentLanguageCode), click to switch").accessibilityHidden(!show)
    }

    /// The eye. Idle: dim outline. Armed: ember, filled, with the shot beside it (springs in from the right). Capturing: a quick blink.
    /// A model looking by itself: the same armed look plus one ring that ripples out, so you see it happened.
    private var eyeChip: some View {
        let on = a.seeScreen || a.looked
        return Button { a.toggleScreen() } label: {
            HStack(spacing: 5) {
                if on, let t = a.shot?.thumb ?? a.glimpse?.thumb {
                    Image(nsImage: t).resizable().frame(width: 22, height: 14).clipShape(RoundedRectangle(cornerRadius: 3))
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Ink.ember.opacity(0.6), lineWidth: 1))
                        .transition(reduce ? .opacity : .scale(scale: 0.4, anchor: .trailing).combined(with: .opacity))
                }
                Image(systemName: on ? "eye.fill" : "eye").font(.system(size: 12))
                    .scaleEffect(y: a.capturing && !reduce ? 0.12 : 1)
                    .animation(.easeInOut(duration: 0.09), value: a.capturing)
                    .overlay {
                        if !reduce {
                            Circle().stroke(Ink.ember, lineWidth: 1.5).frame(width: 16, height: 16)
                                .keyframeAnimator(initialValue: Ping(), trigger: a.lookTick) { v, f in v.scaleEffect(f.s).opacity(f.o) } keyframes: { _ in
                                    KeyframeTrack(\.s) { LinearKeyframe(1, duration: 0.001); CubicKeyframe(2.2, duration: 0.6) }
                                    KeyframeTrack(\.o) { LinearKeyframe(0.8, duration: 0.001); CubicKeyframe(0, duration: 0.6) }
                                }
                        }
                    }
            }
            .foregroundStyle(on ? Ink.ember : Ink.dim).padding(6).contentShape(Rectangle())
            .animation(reduce ? .easeOut(duration: 0.15) : .spring(duration: 0.45, bounce: 0.25), value: on)
        }
        .buttonStyle(.plain).disabled(a.backend == .gemma || a.busy).opacity(a.backend == .gemma ? 0.35 : 1)
        .help(a.backend == .gemma ? "The local model can't see the screen" : "Show the model your screen  ⌥⌘S").accessibilityLabel("Share screen with the model")
    }

    /// Names the model at the notch once, right after a switch (⇥ or ⌘1-3), then lets it go. The row stays empty the rest of the time.
    private func announce() {
        guard a.isOpen, a.mode == .prompt, !a.needsSetup else { return }
        announceTask?.cancel(); announceTick += 1
        withAnimation(reduce ? .easeOut(duration: 0.15) : .spring(duration: 0.45, bounce: 0.1)) { announced = a.backend }
        announceTask = Task {
            try? await Task.sleep(for: .seconds(Self.announceHold))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: reduce ? 0.15 : 0.22)) { announced = nil }          // leaves faster than it arrived
        }
    }

    /// First run with neither CLI installed: say exactly what to do. Gemma is deliberately an afterthought.
    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("One model to start.").font(.system(size: 21, weight: .semibold)).foregroundStyle(Ink.text)
            VStack(alignment: .leading, spacing: 8) {
                setupRow("Claude", "npm install -g @anthropic-ai/claude-code", "then run  claude  once to log in")
                setupRow("Codex", "npm install -g @openai/codex", "then run  codex  once to log in")
            }
            Text("Then press ⌥ Space again. A model on your own server is optional: menu bar → Settings…")
                .font(.system(size: 13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 30).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func setupRow(_ name: String, _ cmd: String, _ then: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Text(name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Ink.ember).frame(width: 52, alignment: .leading)
                Text(cmd).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(Ink.text).textSelection(.enabled)
            }
            Text(then).font(.system(size: 12)).foregroundStyle(Ink.dim).padding(.leading, 62)
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(a.answer, forType: .string)
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

/// The send key. Dim when empty, ember (quiet 0.15 s crossfade, no pop) when there is something to send, a slow breath while an answer is on its way.
private struct ReturnGlyph: View {
    let ready: Bool, busy: Bool, reduce: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: !busy || reduce)) { ctx in
            let breath = busy && !reduce ? 0.3 + 0.2 * (0.5 + 0.5 * sin(ctx.date.timeIntervalSinceReferenceDate * 2.6)) : 1
            Image(systemName: "return")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ready && !busy ? Ink.ember : Ink.dim.opacity(0.5))
                .opacity(busy ? breath : 1)
                .frame(width: 20, height: 24)   // fixed slot: nothing here moves with a keystroke
                .animation(.easeOut(duration: 0.15), value: ready)
        }
    }
}

/// The sent text, lifting off the field as it becomes the question.
private struct GhostText: View {
    let text: String
    @State private var go = false
    var body: some View {
        Text(text).font(.system(size: 19)).foregroundStyle(Ink.text).lineLimit(4)
            .offset(y: go ? -6 : 0).opacity(go ? 0 : 1)
            .onAppear { withAnimation(.easeOut(duration: 0.2)) { go = true } }
    }
}

private struct Ping { var s = 1.0, o = 0.0 }

/// Breathing status dot: steady ember when ready, slow pulse while working, grey when offline.
private struct StatusDot: View {
    let link: Assistant.Link
    let busy: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !(busy || link == .connecting))) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let pulse = (busy || link == .connecting) ? 0.55 + 0.45 * (0.5 + 0.5 * sin(t * 3.2)) : 1
            Circle()
                .fill(link == .offline ? Color.gray.opacity(0.6) : Ink.ember)
                .frame(width: 6, height: 6)
                .opacity(pulse)
                .shadow(color: Ink.ember.opacity(link == .ready ? 0.7 * pulse : 0), radius: 4, y: 1)
        }
    }
}

/// A slow ember glint travelling along the pill's bottom edge while the model thinks.
private struct EmberSweep: View {
    var body: some View {
        TimelineView(.animation) { ctx in
            let p = (ctx.date.timeIntervalSinceReferenceDate / 1.6).truncatingRemainder(dividingBy: 1)
            GeometryReader { g in
                let w = g.size.width * 0.34
                Capsule()
                    .fill(LinearGradient(colors: [.clear, Ink.ember, Ink.emberDeep.opacity(0.9), .clear],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: w, height: 2)
                    .offset(x: -w + (g.size.width + w) * p)
                    .blur(radius: 0.6)
            }
            .frame(height: 2)
        }
        .allowsHitTesting(false)
    }
}

/// One ember pass along the pill's bottom edge when a spoken question is sent; the thinking sweep picks up from there.
private struct SendGlint: View {
    @State private var go = false
    var body: some View {
        GeometryReader { g in
            let w = g.size.width * 0.34
            Capsule()
                .fill(LinearGradient(colors: [.clear, Ink.ember, Ink.emberDeep.opacity(0.9), .clear], startPoint: .leading, endPoint: .trailing))
                .frame(width: w, height: 2.5)
                .offset(x: go ? g.size.width : -w)
                .blur(radius: 0.6)
        }
        .frame(height: 2.5)
        .allowsHitTesting(false)
        .onAppear { withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.38)) { go = true } }
    }
}

/// A slide-and-sharpen for a transition: a short move (never far), opacity, and a blur that resolves as it lands.
private struct Slide: ViewModifier {
    let x: CGFloat, opacity: Double, blur: CGFloat
    func body(content: Content) -> some View { content.offset(x: x).opacity(opacity).blur(radius: blur) }
}

/// The model's mark and name, with an ember hairline under it that drains over the time it stays: the same clock the alert cards use.
private struct ModelAnnounce: View {
    let backend: Backend
    let work: Bool
    let hold: Double
    let reduce: Bool
    @State private var left = 1.0

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 7) {
                ModelMark(backend: backend, size: 17, active: true)
                Text(backend.displayName + (work ? " +" : ""))
                    .font(.system(size: 12.5, weight: .medium)).tracking(0.2).foregroundStyle(Ink.text.opacity(0.9)).lineLimit(1).fixedSize()
            }
            ZStack(alignment: .trailing) {
                Rectangle().fill(Ink.ember.opacity(0.14)).frame(height: 1)
                Rectangle().fill(Ink.ember).frame(height: 1).scaleEffect(x: left, anchor: .trailing)
            }
        }
        .fixedSize()
        .onAppear { if !reduce { withAnimation(.linear(duration: hold)) { left = 0 } } else { left = 0 } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Model: \(backend.displayName)\(work ? ", can edit files" : "")")
    }
}
