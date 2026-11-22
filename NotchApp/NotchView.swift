import SwiftUI

// Ink & ember: pure black that melts into the hardware notch, one warm accent, a quiet sans voice.
enum Ink {
    static let ember = Color(red: 1.00, green: 0.69, blue: 0.35)
    static let emberDeep = Color(red: 0.93, green: 0.42, blue: 0.18)
    static let text = Color(red: 0.95, green: 0.92, blue: 0.87)
    static let dim = Color(red: 0.95, green: 0.92, blue: 0.87).opacity(0.52)
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

    private let openW: CGFloat = 560
    private let inputH: CGFloat = 52
    private var hasAnswer: Bool { !a.turns.isEmpty }
    private static let setupH: CGFloat = 168
    private var bodyH: CGFloat { a.needsSetup ? Self.setupH : hasAnswer ? min((contentH / 8).rounded(.up) * 8, NotchWindow.maxBody) : 0 }
    private var recallH: CGFloat { notch.height + 6 + RecallView.bodyHeight(a) + 12 }
    private var pillH: CGFloat {
        guard a.isOpen else { return notch.height }
        return a.mode == .recall ? recallH : notch.height + 6 + bodyH + inputH + 12
    }

    var body: some View {
        ZStack(alignment: .top) {
            // click on the empty panel area dismisses
            Color.clear.contentShape(Rectangle()).onTapGesture { a.close() }

            pill
            if !a.isOpen { AlertView(c: center, notch: notch) }
            if !a.isOpen { DictationBar(d: Dictation.shared, notch: notch) }
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
        .onChange(of: a.work) { announce() }
        .onChange(of: a.busy) { if !a.busy && a.isOpen { focused = true } } // field is disabled while answering
        .task(id: [a.isOpen ? 1 : 0, a.mode == .prompt ? 1 : 0]) { if a.isOpen && a.mode == .prompt { try? await Task.sleep(for: .milliseconds(120)); focused = true } } // also when switching recall → prompt while open
    }

    private var pill: some View {
        UnevenRoundedRectangle(bottomLeadingRadius: a.isOpen ? 26 : 10, bottomTrailingRadius: a.isOpen ? 26 : 10)
            .fill(.black)
            .frame(width: a.isOpen ? openW : notch.width, height: pillH)
            .overlay(alignment: .top) { content }
            .overlay(alignment: .bottom) { if a.isOpen && a.mode == .prompt && a.busy && a.waiting { EmberSweep().transition(.opacity) } }
            .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: a.isOpen ? 26 : 10, bottomTrailingRadius: a.isOpen ? 26 : 10))
            .animation(.spring(duration: 0.5, bounce: 0.22), value: a.isOpen)
            .animation(.smooth(duration: 0.28), value: pillH)
    }

    private var content: some View {
        VStack(spacing: 0) {
            wings.frame(height: notch.height)
            if a.mode == .recall {
                RecallView(a: a).padding(.top, 6)
            } else {
                if a.needsSetup { setupCard.frame(height: bodyH).padding(.top, 6) }
                else if hasAnswer { transcript.frame(height: bodyH).padding(.top, 6) }
                inputRow.padding(.top, hasAnswer || a.needsSetup ? 0 : 6)
            }
        }
        .frame(width: openW)
        // content arrives after the shell has opened, leaves before it closes
        .opacity(a.isOpen ? 1 : 0)
        .blur(radius: a.isOpen ? 0 : 8)
        .animation(.easeOut(duration: a.isOpen ? 0.3 : 0.12).delay(a.isOpen ? 0.14 : 0), value: a.isOpen)
    }

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

    private var inputRow: some View {
        HStack(spacing: 10) {
            TextField("", text: $a.draft,
                      prompt: Text(a.needsSetup ? "Install claude or codex to begin" : a.backend == .gemma ? (hasAnswer ? "Follow up…" : "Ask anything") : (a.work && !hasAnswer ? "Ask \(a.backend.rawValue) · ⌘F folder" : "Ask \(a.backend.rawValue)…")).foregroundStyle(Ink.dim))
                .textFieldStyle(.plain)
                .font(.system(size: 19))
                .foregroundStyle(Ink.text)
                .tint(Ink.ember)
                .focused($focused)
                .disabled(a.busy)
                .onSubmit { a.send() }
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
            eyeChip
            Image(systemName: "return")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(a.draft.isEmpty && !a.seeScreen ? Ink.dim.opacity(0.5) : Ink.ember)
                .animation(.easeOut(duration: 0.15), value: a.draft.isEmpty && !a.seeScreen)
        }
        .padding(.horizontal, 30)
        .frame(height: inputH)
        .background(
            // hairline, not a box
            Rectangle().fill(Ink.text.opacity(hasAnswer ? 0.08 : 0)).frame(height: 1).padding(.horizontal, 26),
            alignment: .top)
        .background(Button("") { copy() }.keyboardShortcut("c", modifiers: [.command, .shift]).opacity(0).allowsHitTesting(false))
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

/// ⌥V dictation, shown under the closed notch: ember level bars and the words so far, or a short message.
private struct DictationBar: View {
    var d: Dictation
    let notch: CGSize
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        Group {
            switch d.state {
            case .idle: EmptyView()
            case .listening(let partial, let level):
                HStack(spacing: 8) {
                    HStack(spacing: 2) {
                        ForEach(0..<4, id: \.self) { i in
                            Capsule().fill(Ink.ember).frame(width: 2.5, height: 4 + 10 * CGFloat(reduce ? 0.3 : min(1, level * (0.6 + 0.2 * Float(i)))))
                        }
                    }.frame(height: 14)
                    Text(partial.isEmpty ? "Listening…" : partial).lineLimit(1).truncationMode(.head)
                }
                .animation(reduce ? nil : .easeOut(duration: 0.08), value: level)
            case .message(let m): Text(m).lineLimit(1)
            }
        }
        .font(.system(size: 11, weight: .medium)).foregroundStyle(Ink.text)
        .padding(.horizontal, 12).frame(height: d.state == .idle ? 0 : 26)
        .frame(maxWidth: 320)
        .background(.black, in: Capsule())
        .fixedSize()
        .padding(.top, notch.height + 6)
        .opacity(d.state == .idle ? 0 : 1)
        .animation(reduce ? nil : .smooth(duration: 0.2), value: d.state == .idle)
        .allowsHitTesting(false)
    }
}
