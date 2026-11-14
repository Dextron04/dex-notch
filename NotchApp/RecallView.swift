import SwiftUI

/// ⌥⇧Space: what the agents recorded, and the last conversation with each one.
struct RecallView: View {
    @Bindable var a: Assistant
    static let rowH: CGFloat = 46
    static let maxRows = 6

    @FocusState private var searchFocus: Bool
    @State private var shown = 0     // counter that counts up on open
    @State private var rowsIn = false

    private var rows: ArraySlice<AgentSummary> { a.recallRows.prefix(Self.maxRows) }

    var body: some View {
        VStack(spacing: 0) {
            header.frame(height: 44)
            if rows.isEmpty { empty } else { list }
            if a.summarizing || !a.summary.isEmpty { summary }
            footer.frame(height: 36)
        }
        .padding(.horizontal, 18)
        .task(id: a.isOpen) {
            guard a.isOpen else { rowsIn = false; return }
            rowsIn = false; try? await Task.sleep(for: .milliseconds(160)); rowsIn = true
        }
        .task(id: a.snapshot.totalSessions) { await countUp(to: a.snapshot.totalSessions) }
        .onChange(of: a.searching) { if a.searching { searchFocus = true } }
    }

    // MARK: header: counters, or the search field after "/"

    @ViewBuilder private var header: some View {
        if a.searching {
            HStack(spacing: 10) {
                TextField("", text: $a.recallQuery, prompt: Text("Search conversations").foregroundStyle(Ink.dim))
                    .textFieldStyle(.plain).font(.system(size: 18, design: .serif)).italic(a.recallQuery.isEmpty)
                    .foregroundStyle(Ink.text).tint(Ink.ember).focused($searchFocus)
                    .onSubmit { a.openSelectedNote() }
                Text("\(a.recallRows.count)").font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(Ink.dim)
            }.padding(.horizontal, 12)
        } else {
            (Text("\(shown)").foregroundColor(Ink.ember).font(.system(size: 22, weight: .semibold, design: .serif))
             + Text(" conversations across ").foregroundColor(Ink.dim)
             + Text("\(a.snapshot.agents.count)").foregroundColor(Ink.text)
             + Text(" agents").foregroundColor(Ink.dim)
             + Text(a.snapshot.todayCount > 0 ? "  ·  \(a.snapshot.todayCount) today" : "").foregroundColor(Ink.dim))
                .font(.system(size: 14, design: .serif))
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12)
                .contentTransition(.numericText())
        }
    }

    private func countUp(to n: Int) async {
        shown = 0
        guard n > 0 else { return }
        let steps = min(n, 24)
        for i in 1...steps {
            try? await Task.sleep(for: .milliseconds(22))
            withAnimation(.snappy(duration: 0.12)) { shown = n * i / steps }
        }
    }

    // MARK: rows

    private var list: some View {
        VStack(spacing: 2) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                row(r, selected: i == a.recallIndex)
                    .opacity(rowsIn ? 1 : 0).offset(y: rowsIn ? 0 : 7)
                    .animation(.easeOut(duration: 0.38).delay(Double(i) * 0.045), value: rowsIn)
                    .onTapGesture(count: 2) { a.recallIndex = i; a.openSelectedNote() }
                    .onTapGesture { a.recallIndex = i; a.moveSelection(0) }
            }
        }
    }

    private func row(_ r: AgentSummary, selected: Bool) -> some View {
        HStack(spacing: 12) {
            Text(r.name).font(.system(size: 11, weight: .medium, design: .monospaced)).tracking(0.2)
                .foregroundStyle(r.state == "ok" ? Ink.ember : Ink.dim).frame(width: 84, alignment: .leading).lineLimit(1)
            VStack(alignment: .leading, spacing: 1) {
                Text(r.lastTitle).font(.system(size: 15, design: .serif)).foregroundStyle(selected ? Ink.text : Ink.text.opacity(0.82)).lineLimit(1)
                Text(r.lastProject + (r.sessions > 1 ? "  ·  \(r.sessions) sessions" : "")).font(.system(size: 11)).foregroundStyle(Ink.dim).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(Self.age(r.lastUpdated)).font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(Ink.dim)
        }
        .padding(.horizontal, 12).frame(height: Self.rowH - 2)
        .background(selected ? Ink.text.opacity(0.075) : .clear, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.14), value: selected)
    }

    static func age(_ d: Date) -> String {
        let s = Int(Date().timeIntervalSince(d))
        if s < 60 { return "now" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }

    private var empty: some View {
        Text(a.searching ? "No conversation matches." : "Nothing recorded yet. This fills in as you work with your agents.")
            .font(.system(size: 15, design: .serif)).italic().foregroundStyle(Ink.dim)
            .frame(maxWidth: .infinity, minHeight: Self.rowH, alignment: .leading).padding(.horizontal, 12)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Ink.text.opacity(0.08)).frame(height: 1).padding(.bottom, 9)
            Text(a.summary.isEmpty ? "summarising…" : a.summary)
                .font(.system(size: 14, design: .serif)).lineSpacing(3).italic(a.summary.isEmpty)
                .foregroundStyle(a.summary.isEmpty ? Ink.dim : Ink.text).lineLimit(4)
        }
        .padding(.horizontal, 12).padding(.top, 6).frame(height: 76, alignment: .top).clipped()
    }

    private var footer: some View {
        HStack(spacing: 16) {
            ForEach([("↑↓", "move"), ("↩", "open"), ("⌘↩", "summarize"), ("/", "search")], id: \.0) { k, l in
                HStack(spacing: 5) { Text(k).foregroundStyle(Ink.text.opacity(0.75)); Text(l).foregroundStyle(Ink.dim) }
            }
            Spacer()
        }
        .font(.system(size: 11, weight: .medium)).tracking(0.3).padding(.horizontal, 12)
    }
}
