import SwiftUI

/// The card grown into a place to answer: the AI's draft (yours to edit), a tab to ask about the email, and Send or Save draft.
/// The AI only ever writes the text. Who it goes to and the subject come from the email itself, and nothing is sent until you press Send.
struct ReplyPanel: View {
    var c: AddonCenter
    @Bindable var s: ReplySession
    let notch: CGSize
    @FocusState private var focus: Field?
    @Namespace private var tabNS
    @Environment(\.accessibilityReduceMotion) private var reduce
    enum Field { case draft, input }

    static let bodyH: CGFloat = 206
    private var sealed: Bool { s.outcome == .sent || s.outcome == .saved }

    var body: some View {
        VStack(spacing: 0) {
            wings
            switch s.stage {
            case .needsPermission: permission
            case .loading: message("Reading the email…", pulse: true)
            case .failed(let why): message(why, pulse: false, retry: true)
            case .ready:
                ready
                    .opacity(sealed ? 0 : 1).blur(radius: sealed ? 8 : 0).scaleEffect(sealed ? 0.97 : 1)       // the panel steps back so the check has the room
                    .animation(reduce ? .easeOut(duration: 0.15) : .timingCurve(0.23, 1, 0.32, 1, duration: 0.3), value: sealed)
                    .overlay {
                        if sealed {
                            SentSeal(sent: s.outcome == .sent, title: s.outcome == .sent ? "Sent" : "Saved", detail: s.outcome == .sent ? "to \(s.recipientName)" : "in your Gmail drafts. Finish it any time.")
                                .padding(.top, 8).transition(.opacity)
                        }
                    }
            }
        }
        .frame(width: AlertView.replyWidth)
        .transition(.opacity)
        .task(id: s.stage) { if s.stage == .ready { try? await Task.sleep(for: .milliseconds(250)); focus = .input } }
        .onChange(of: s.busy) { if !s.busy, s.stage == .ready { focus = .input } }            // the field is off while the agent writes; the caret comes back with it
        .onChange(of: s.outcome) { if s.outcome == .none, s.stage == .ready { focus = .input } }        // after Undo
    }

    // MARK: pieces

    private var wings: some View {
        HStack(spacing: 0) {
            HStack(spacing: 7) {
                AddonMark(addon: s.alert.addon, size: 17)
                Text("Reply").font(.system(size: 11, weight: .medium)).tracking(0.3).foregroundStyle(Ink.dim)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 26)
            Color.clear.frame(width: notch.width)
            Text(s.recipientName).font(.system(size: 11, weight: .medium)).tracking(0.3).foregroundStyle(Ink.text.opacity(0.75)).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 26)
        }
        .frame(height: notch.height)
    }

    private func message(_ text: String, pulse: Bool, retry: Bool = false) -> some View {
        VStack(spacing: 14) {
            Text(text).font(.system(size: 15, design: .serif)).italic().foregroundStyle(Ink.dim).multilineTextAlignment(.center)
                .opacity(pulse ? 0.6 : 1).fixedSize(horizontal: false, vertical: true)
            if retry { link("Try again") { c.startReply() } }
            link("Close", dim: true) { c.collapseReply() }
        }
        .padding(.horizontal, 40).frame(maxWidth: .infinity, minHeight: 250)
    }

    private var permission: some View {
        VStack(spacing: 14) {
            Text("To write replies, Google needs to let Dex Notch create drafts and send mail from \(s.alert.account ?? "this account"). It only does so when you press Send or Save draft.")
                .font(.system(size: 15, design: .serif)).foregroundStyle(Ink.text.opacity(0.9)).multilineTextAlignment(.center).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            if let n = s.note { Text(n).font(.system(size: 13, design: .serif)).italic().foregroundStyle(Ink.dim) }
            link("Allow replies") { c.allowReplies() }
            link("Not now", dim: true) { c.collapseReply() }
        }
        .padding(.horizontal, 52).frame(maxWidth: .infinity, minHeight: 250)
    }

    private var ready: some View {
        VStack(spacing: 0) {
            tabs
            Group { s.tab == .draft ? AnyView(draftBody) : AnyView(askBody) }
                .frame(height: Self.bodyH).padding(.horizontal, 28)
            Text(s.tab == .draft ? (s.note ?? " ") : " ").font(.system(size: 12, design: .serif)).italic().foregroundStyle(Ink.dim).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 28).padding(.top, 4).frame(height: 22)
            inputRow
            actions
        }
    }

    private var tabs: some View {
        HStack(spacing: 22) {
            tab("Draft", .draft); tab("Ask about this email", .ask)
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                ForEach(c.agents, id: \.self) { b in
                    Button { c.useAgent(b) } label: { ModelMark(backend: b, size: 15, active: b == s.backend).padding(5).contentShape(Rectangle()) }
                        .buttonStyle(.plain).help("Have \(b.displayName) write it").disabled(s.busy)
                }
            }
        }
        .padding(.horizontal, 28).frame(height: 38)
    }

    private func tab(_ title: String, _ t: ReplySession.Tab) -> some View {
        let on = s.tab == t
        return Button { withAnimation(.spring(duration: 0.3, bounce: 0.1)) { s.tab = t }; focus = .input } label: {
            Text(title).font(.system(size: 15, weight: on ? .semibold : .regular, design: .serif)).foregroundStyle(on ? Ink.ember : Ink.dim)
                .padding(.vertical, 6).contentShape(Rectangle())
                .overlay(alignment: .bottom) { if on { Rectangle().fill(Ink.ember).frame(height: 1).matchedGeometryEffect(id: "tab", in: tabNS) } }
        }.buttonStyle(.plain)
    }

    private var draftBody: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $s.draft)
                .focused($focus, equals: .draft)
                .font(.system(size: 15, design: .serif)).foregroundStyle(Ink.text).tint(Ink.ember).lineSpacing(3)
                .scrollContentBackground(.hidden).scrollIndicators(.never)
                .padding(.top, 6).disabled(s.drafting).opacity(s.drafting ? 0.35 : 1)
            if s.drafting {
                Text(s.draft.isEmpty ? "Writing a reply…" : "Rewriting…").font(.system(size: 15, design: .serif)).italic().foregroundStyle(Ink.dim).padding(.top, 8).padding(.leading, 5)
            }
        }
        .animation(.easeOut(duration: 0.2), value: s.drafting)
    }

    private var askBody: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if s.exchanges.isEmpty {
                        Text("Ask anything about this email: what it wants from you, what a date or a term means, whether it looks genuine.")
                            .font(.system(size: 14, design: .serif)).italic().foregroundStyle(Ink.dim).lineSpacing(3)
                    }
                    ForEach(s.exchanges) { e in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(e.question).font(.system(size: 13, design: .serif)).italic().foregroundStyle(Ink.dim)
                            if e.answer.isEmpty { Text("Thinking…").font(.system(size: 15, design: .serif)).foregroundStyle(Ink.dim).opacity(0.6) }
                            else { Text(e.answer).font(.system(size: 15, design: .serif)).foregroundStyle(Ink.text).lineSpacing(3).textSelection(.enabled) }
                        }.id(e.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10).padding(.bottom, 4)
            }
            .scrollIndicators(.never)
            .onChange(of: s.exchanges.count) { if let l = s.exchanges.last { withAnimation { proxy.scrollTo(l.id, anchor: .bottom) } } }
            .onChange(of: s.exchanges.last?.answer) { if let l = s.exchanges.last { proxy.scrollTo(l.id, anchor: .bottom) } }
        }
    }

    private var inputRow: some View {
        HStack(spacing: 10) {
            TextField("", text: $s.input,
                      prompt: Text(s.tab == .draft ? "Tell it what to change…  “shorter”, “say Thursday doesn't work”" : "Ask about this email…").foregroundStyle(Ink.dim))
                .textFieldStyle(.plain).font(.system(size: 16, design: .serif)).italic(s.input.isEmpty).foregroundStyle(Ink.text).tint(Ink.ember)
                .focused($focus, equals: .input).disabled(s.busy).onSubmit { c.submitInput() }
            Image(systemName: "return").font(.system(size: 12, weight: .semibold)).foregroundStyle(s.input.isEmpty ? Ink.dim.opacity(0.5) : Ink.ember)
        }
        .padding(.horizontal, 28).frame(height: 44)
        .background(Rectangle().fill(Ink.text.opacity(0.08)).frame(height: 1).padding(.horizontal, 26), alignment: .top)
    }

    private var actions: some View {
        HStack(spacing: 20) {
            switch s.outcome {
            case .none, .failed:
                Button { c.beginSend() } label: {
                    Text("Send to \(s.recipientName)").font(.system(size: 14, weight: .semibold, design: .serif)).foregroundStyle(.black).lineLimit(1)
                        .padding(.horizontal, 18).padding(.vertical, 7).background(Capsule().fill(s.canSend ? Ink.ember : Ink.ember.opacity(0.3)))
                }.buttonStyle(.plain).keyboardShortcut(.return, modifiers: .command).disabled(!s.canSend)
                link("Save draft", dim: false) { c.saveDraft() }.keyboardShortcut("s", modifiers: .command).disabled(!s.canSend).opacity(s.canSend ? 1 : 0.4)
                link("Discard", dim: true) { c.discardReply() }
                Spacer(minLength: 8)
                if case .failed(let why) = s.outcome { Text(why).font(.system(size: 12, design: .serif)).foregroundStyle(Ink.emberDeep).lineLimit(2) }
                else { Text("esc keeps the draft for later").font(.system(size: 12, design: .serif)).italic().foregroundStyle(Ink.dim) }
            case .undo(let n):
                Text("Sending in \(n)…").font(.system(size: 15, weight: .semibold, design: .serif)).foregroundStyle(Ink.ember)
                link("Undo") { c.undoSend() }.keyboardShortcut("z", modifiers: .command)
                Spacer()
            case .sending:
                Text("Sending…").font(.system(size: 15, design: .serif)).italic().foregroundStyle(Ink.dim); Spacer()
            case .sent:
                Label("Sent", systemImage: "checkmark").font(.system(size: 15, weight: .semibold, design: .serif)).foregroundStyle(Ink.ember); Spacer()
            case .saved:
                Label("Saved to your Gmail drafts", systemImage: "checkmark").font(.system(size: 15, weight: .semibold, design: .serif)).foregroundStyle(Ink.ember); Spacer()
            }
        }
        .padding(.horizontal, 28).frame(height: 54)
        .animation(.easeOut(duration: 0.2), value: s.outcome)
    }

    private func link(_ title: String, dim: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).font(.system(size: 14, weight: .semibold, design: .serif)).foregroundStyle(dim ? Ink.dim : Ink.ember).contentShape(Rectangle()) }.buttonStyle(.plain)
    }
}

/// The reply as a letter. It slides into an envelope, the flap closes, a seal is pressed, and a sent letter flies out of the notch (a saved
/// one stays, sealed). The rim comet runs round the pill at the same time, as it does for everything the notch has to say.
/// A rare moment, so it gets about a second and a half; everything lands on one strong ease-out and nothing bounces.
struct SentSeal: View {
    let sent: Bool
    let title: String
    let detail: String
    @State private var paperIn = false      // the letter has slid inside
    @State private var closed = false       // the flap is down
    @State private var sealed = false       // the seal is pressed
    @State private var gone = false         // the envelope has left
    @State private var words = false
    @State private var wake = false         // the trail is showing
    @Environment(\.accessibilityReduceMotion) private var reduce

    private func out(_ d: Double, delay: Double = 0) -> Animation { .timingCurve(0.23, 1, 0.32, 1, duration: d).delay(delay) }
    private static let w: CGFloat = 104, h: CGFloat = 72

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                ForEach(0..<3, id: \.self) { i in                                  // the wake it leaves as it goes: faint outlines that follow it out
                    RoundedRectangle(cornerRadius: 7).stroke(Ink.ember, lineWidth: 1.5)
                        .frame(width: Self.w, height: Self.h)
                        .offset(x: gone ? 190 : 0, y: gone ? -210 : 0).rotationEffect(.degrees(gone ? -16 : 0)).scaleEffect(gone ? 0.45 : 1)
                        .opacity(wake ? 0.34 - 0.1 * Double(i) : 0)
                        .animation(out(0.85, delay: 0.07 * Double(i + 1)), value: gone)
                        .animation(.easeOut(duration: 0.3), value: wake)
                }
                envelope
                    .offset(x: gone ? 190 : 0, y: gone ? -210 : 0).rotationEffect(.degrees(gone ? -16 : 0)).scaleEffect(gone ? 0.45 : 1)
                    .opacity(gone ? 0 : 1)
                    .animation(out(0.85), value: gone)
                    .animation(.easeOut(duration: 0.35).delay(0.5), value: gone)       // fades only once it is most of the way out
            }
            .frame(width: Self.w + 20, height: Self.h + 56)
            VStack(spacing: 5) {
                Text(title).font(.system(size: 26, weight: .semibold, design: .serif)).foregroundStyle(Ink.text)
                Text(detail).font(.system(size: 15, design: .serif)).italic().foregroundStyle(Ink.dim)
            }
            .opacity(words ? 1 : 0).blur(radius: words || reduce ? 0 : 6).offset(y: words || reduce ? 0 : 6)
        }
        .accessibilityElement(children: .combine).accessibilityLabel("\(title) \(detail)")
        .task {
            if reduce { withAnimation(.easeOut(duration: 0.2)) { paperIn = true; closed = true; sealed = true; words = true }; return }
            try? await Task.sleep(for: .milliseconds(120)); withAnimation(out(0.5)) { paperIn = true }                    // the letter goes in
            try? await Task.sleep(for: .milliseconds(420)); withAnimation(out(0.4)) { closed = true }                     // the flap closes
            try? await Task.sleep(for: .milliseconds(330))
            withAnimation(out(0.28)) { sealed = true }                                                                    // the seal is pressed
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)
            try? await Task.sleep(for: .milliseconds(200))
            if sent { gone = true; wake = true }                                                                          // and a sent letter leaves
            withAnimation(out(0.5, delay: sent ? 0.1 : 0)) { words = true }
            try? await Task.sleep(for: .milliseconds(550)); wake = false
        }
    }

    // MARK: the envelope

    private var envelope: some View {
        let W = Self.w, H = Self.h
        return ZStack {
            RoundedRectangle(cornerRadius: 7).fill(Color(red: 0.11, green: 0.10, blue: 0.09))                          // the back of the envelope
            RoundedRectangle(cornerRadius: 7).stroke(Ink.text.opacity(0.85), lineWidth: 2)
            // the letter: bigger and above the pocket, then in
            RoundedRectangle(cornerRadius: 3).fill(Ink.text)
                .overlay(VStack(spacing: 6) { ForEach(0..<3, id: \.self) { i in Capsule().fill(Color.black.opacity(0.28)).frame(width: i == 2 ? 28 : 52, height: 3) } }.frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 12))
                .frame(width: W - 26, height: H - 20)
                .scaleEffect(paperIn ? 0.94 : 1.22).offset(y: paperIn ? 4 : -50)
            // the pocket in front, hiding the letter's lower part
            Pocket().fill(Color(red: 0.11, green: 0.10, blue: 0.09))
            Pocket().stroke(Ink.text.opacity(0.85), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
            // the flap, hinged along the top edge
            Flap().fill(Color(red: 0.15, green: 0.13, blue: 0.11))
                .overlay(Flap().stroke(Ink.text.opacity(0.85), style: StrokeStyle(lineWidth: 2, lineJoin: .round)))
                .rotation3DEffect(.degrees(closed ? 0 : 180), axis: (x: 1, y: 0, z: 0), anchor: .top, perspective: 0.5)
                .offset(y: closed ? 0 : -1)
            // the seal
            Circle().fill(Ink.ember).frame(width: 15, height: 15).shadow(color: Ink.ember.opacity(0.7), radius: 5)
                .position(x: W / 2, y: H * 0.56).scaleEffect(sealed ? 1 : 0.01).opacity(sealed ? 1 : 0)
        }
        .frame(width: W, height: H)
    }

    private struct Pocket: Shape {
        func path(in r: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.midX, y: r.minY + r.height * 0.58))       // the same V as the flap, so a closed envelope has one clean seam
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.closeSubpath()
            return p
        }
    }
    private struct Flap: Shape {
        func path(in r: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY)); p.addLine(to: CGPoint(x: r.midX, y: r.minY + r.height * 0.58)); p.closeSubpath()
            return p
        }
    }
}
