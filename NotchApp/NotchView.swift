import SwiftUI

// Ink & ember: pure black that melts into the hardware notch, one warm accent, a serif voice.
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

    @FocusState private var focused: Bool
    @Namespace private var dialNS
    @State private var contentH: CGFloat = 0

    private let openW: CGFloat = 560
    private let inputH: CGFloat = 52
    private var hasAnswer: Bool { !a.turns.isEmpty }
    private var bodyH: CGFloat { hasAnswer ? min((contentH / 8).rounded(.up) * 8, NotchWindow.maxBody) : 0 }
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
        }
        .frame(width: panel.width, height: panel.height, alignment: .top)
        .onKeyPress(.escape) { a.close(); return .handled }
        .onChange(of: a.backend) { focused = true } // a click on the dial must not strand the caret
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
                if hasAnswer { transcript.frame(height: bodyH).padding(.top, 6) }
                inputRow.padding(.top, hasAnswer ? 0 : 6)
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
                else if a.mode == .prompt && !hasAnswer && !a.busy { hint("⇥", "model") }
                hint("esc", "close")
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 26)
        }
    }

    private var statusText: String {
        if a.mode == .recall { return a.snapshot.recorderOK ? "recorder · running" : "recorder · not running" }
        if a.backend != .gemma {
            return a.busy ? (a.toolNote.map { "\(a.backend.rawValue) · using \($0)" } ?? "\(a.backend.rawValue) · thinking")
                          : (a.work ? "\(a.backend.rawValue)+ · \(a.folder ?? "sandbox")" : "\(a.backend.rawValue) · subscription")
        }
        return switch a.link {
        case .ready: a.waiting ? "thinking" : "gemma · mac-mini"
        case .connecting: "connecting to \(Assistant.host)…"
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
                        Text(q).font(.system(size: 13, design: .serif)).foregroundStyle(Ink.dim).lineLimit(2)
                    }
                    if let e = a.error {
                        Text(e).font(.system(size: 15, design: .serif)).foregroundStyle(Ink.emberDeep)
                    } else if !a.answer.isEmpty {
                        AnswerBody(text: a.answer)
                        if !a.recalled.isEmpty && !a.busy {
                            Text("from your vault · " + a.recalled.prefix(3).joined(separator: " · "))
                                .font(.system(size: 11, design: .serif)).italic().foregroundStyle(Ink.dim).lineLimit(2)
                        }
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 30)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
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
                      prompt: Text(a.backend == .gemma ? (hasAnswer ? "Follow up…" : "Ask anything") : (a.work && !hasAnswer ? "Ask \(a.backend.rawValue) · ⌘F folder" : "Ask \(a.backend.rawValue)…")).foregroundStyle(Ink.dim))
                .textFieldStyle(.plain)
                .font(.system(size: 19, design: .serif)).italic(!hasAnswer && a.draft.isEmpty)
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
            dial
            Image(systemName: "return")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(a.draft.isEmpty ? Ink.dim.opacity(0.5) : Ink.ember)
                .animation(.easeOut(duration: 0.15), value: a.draft.isEmpty)
        }
        .padding(.horizontal, 30)
        .frame(height: inputH)
        .background(
            // hairline, not a box
            Rectangle().fill(Ink.text.opacity(hasAnswer ? 0.08 : 0)).frame(height: 1).padding(.horizontal, 26),
            alignment: .top)
        .background(Button("") { copy() }.keyboardShortcut("c", modifiers: [.command, .shift]).opacity(0).allowsHitTesting(false))
    }

    /// Three positions, one ember underline that slides to the active model. "+" = may edit files.
    private var dial: some View {
        HStack(spacing: 14) {
            ForEach(AgentStream.order, id: \.self) { b in
                let on = b == a.backend
                Button { a.setBackend(b) } label: {
                    VStack(spacing: 3) {
                        HStack(spacing: 0) {
                            Text(b.rawValue)
                            if on && a.work { Text("+").foregroundStyle(Ink.emberDeep) }
                        }
                        .font(.system(size: 12.5, weight: on ? .semibold : .regular, design: .serif))
                        .foregroundStyle(on ? Ink.ember : Ink.dim)
                        ZStack {
                            Color.clear.frame(height: 1)
                            if on { Rectangle().fill(Ink.ember).frame(height: 1).matchedGeometryEffect(id: "underline", in: dialNS) }
                        }
                    }
                    .padding(.vertical, 4).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(b.rawValue)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: a.backend)
        .animation(.easeOut(duration: 0.15), value: a.work)
        .opacity(a.busy ? 0.4 : 1).allowsHitTesting(!a.busy)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(a.answer, forType: .string)
    }
}

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
