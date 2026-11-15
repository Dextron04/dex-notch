import SwiftUI

/// ⌥⇧Space: what the agents recorded. Three pages (⇥ or ←/→): last chats, activity heatmap, projects.
struct RecallView: View {
    @Bindable var a: Assistant
    static let rowH: CGFloat = 46
    static let maxRows = 6
    static let maxDayRows = 3
    static let dayRowH: CGFloat = 40
    static let projRowH: CGFloat = 34
    private static let tabsH: CGFloat = 30, headerH: CGFloat = 44, footerH: CGFloat = 36, heatRowH: CGFloat = 22, summaryH: CGFloat = 76

    /// Height of everything under the wings, per page. The pill uses this to size itself.
    static func bodyHeight(_ a: Assistant) -> CGFloat {
        let summary = a.summarizing || !a.summary.isEmpty ? summaryH : 0
        switch a.page {
        case .chats: return tabsH + headerH + CGFloat(max(min(a.recallRows.count, maxRows), 1)) * rowH + summary + footerH
        case .activity: return tabsH + headerH + CGFloat(max(a.grid.agents.count, 1)) * heatRowH + 22
                                + CGFloat(max(min(a.daySessions.count, maxDayRows), 1)) * dayRowH + summary + footerH
        case .projects: return tabsH + headerH + CGFloat(max(a.projectStats.count, 1)) * projRowH + footerH
        }
    }

    @FocusState private var searchFocus: Bool
    @State private var shown = 0     // counter that counts up on open
    @State private var rowsIn = false
    @State private var sweepStart = Date()

    private var rows: ArraySlice<AgentSummary> { a.recallRows.prefix(Self.maxRows) }

    var body: some View {
        VStack(spacing: 0) {
            tabs.frame(height: Self.tabsH)
            Group {
                switch a.page {
                case .chats: chatsPage
                case .activity: activityPage
                case .projects: projectsPage
                }
            }
            .id(a.page)
            .transition(.opacity)
            footer.frame(height: Self.footerH)
        }
        .padding(.horizontal, 18)
        .animation(.easeOut(duration: 0.22), value: a.page)
        .task(id: a.isOpen) {
            guard a.isOpen else { rowsIn = false; return }
            rowsIn = false; try? await Task.sleep(for: .milliseconds(160)); rowsIn = true
        }
        .task(id: a.snapshot.totalSessions) { await countUp(to: a.snapshot.totalSessions) }
        .task(id: a.page) { sweepStart = Date(); rowsIn = false; try? await Task.sleep(for: .milliseconds(60)); rowsIn = true }
        .onChange(of: a.searching) { if a.searching { searchFocus = true } }
    }

    // MARK: tabs

    private var tabs: some View {
        HStack(spacing: 22) {
            ForEach(Assistant.RecallPage.allCases, id: \.self) { p in
                HStack(spacing: 6) {
                    Circle().fill(Ink.ember).frame(width: 4, height: 4).opacity(a.page == p ? 1 : 0)
                    Text(p.label).font(.system(size: 13, weight: a.page == p ? .semibold : .regular))
                        .foregroundStyle(a.page == p ? Ink.text : Ink.dim)
                }
                .contentShape(Rectangle()).onTapGesture { a.setPage(p) }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .animation(.easeOut(duration: 0.18), value: a.page)
    }

    // MARK: page 1: last chats

    private var chatsPage: some View {
        VStack(spacing: 0) {
            header.frame(height: Self.headerH)
            if rows.isEmpty { empty } else { list(Array(rows), height: Self.rowH, selectable: true) }
            if a.summarizing || !a.summary.isEmpty { summary }
        }
    }

    @ViewBuilder private var header: some View {
        if a.searching {
            HStack(spacing: 10) {
                TextField("", text: $a.recallQuery, prompt: Text("Search conversations").foregroundStyle(Ink.dim))
                    .textFieldStyle(.plain).font(.system(size: 18))
                    .foregroundStyle(Ink.text).tint(Ink.ember).focused($searchFocus)
                    .onSubmit { a.openSelectedNote() }
                Text("\(a.recallRows.count)").font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(Ink.dim)
            }.padding(.horizontal, 12)
        } else {
            (Text("\(shown)").foregroundColor(Ink.ember).font(.system(size: 22, weight: .semibold))
             + Text(" conversations across ").foregroundColor(Ink.dim)
             + Text("\(a.snapshot.agents.count)").foregroundColor(Ink.text)
             + Text(" agents").foregroundColor(Ink.dim)
             + Text(a.snapshot.todayCount > 0 ? "  ·  \(a.snapshot.todayCount) today" : "").foregroundColor(Ink.dim))
                .font(.system(size: 14))
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

    // MARK: page 2: activity heatmap

    private var activityPage: some View {
        VStack(spacing: 0) {
            activityHeader.frame(height: Self.headerH)
            if a.grid.agents.isEmpty {
                Text("No activity in the last ten weeks.").font(.system(size: 15)).foregroundStyle(Ink.dim)
                    .frame(maxWidth: .infinity, minHeight: Self.heatRowH + 22, alignment: .leading).padding(.horizontal, 12)
            } else {
                Heatmap(grid: a.grid, cursor: a.cursor, start: sweepStart, onPick: { a.setCursor($0) })
                    .frame(height: CGFloat(a.grid.agents.count) * Self.heatRowH + 22).padding(.horizontal, 12)
            }
            if a.daySessions.isEmpty {
                Text("Nothing recorded that day.").font(.system(size: 14)).foregroundStyle(Ink.dim)
                    .frame(maxWidth: .infinity, minHeight: Self.dayRowH, alignment: .leading).padding(.horizontal, 12)
            } else {
                list(Array(a.daySessions.prefix(Self.maxDayRows)), height: Self.dayRowH, selectable: true)
            }
            if a.summarizing || !a.summary.isEmpty { summary }
        }
    }

    private var activityHeader: some View {
        let day = a.grid.days.indices.contains(a.cursor) ? a.grid.days[a.cursor] : Date()
        let n = a.grid.total(onDay: a.cursor)
        return (Text(Self.dayLabel(day)).foregroundColor(Ink.ember).font(.system(size: 20, weight: .semibold))
                + Text(n == 0 ? "  ·  quiet" : "  ·  \(n) session\(n == 1 ? "" : "s")").foregroundColor(Ink.dim))
            .font(.system(size: 14))
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12)
    }

    static func dayLabel(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "EEE, MMM d"; return f.string(from: d)
    }

    // MARK: page 3: projects

    private var projectsPage: some View {
        VStack(spacing: 0) {
            (Text("\(a.projectStats.count)").foregroundColor(Ink.ember).font(.system(size: 22, weight: .semibold))
             + Text(" busiest projects, by turns").foregroundColor(Ink.dim))
                .font(.system(size: 14))
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).frame(height: Self.headerH)
            if a.projectStats.isEmpty { empty } else {
                let top = max(a.projectStats.first?.turns ?? 1, 1)
                ForEach(Array(a.projectStats.enumerated()), id: \.element.name) { i, p in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.name).font(.system(size: 14)).foregroundStyle(Ink.text).lineLimit(1)
                            Text("\(p.sessions) session\(p.sessions == 1 ? "" : "s")").font(.system(size: 10.5)).foregroundStyle(Ink.dim)
                        }.frame(width: 150, alignment: .leading)
                        GeometryReader { g in
                            Capsule().fill(Ink.text.opacity(0.07))
                            Capsule().fill(LinearGradient(colors: [Ink.emberDeep, Ink.ember], startPoint: .leading, endPoint: .trailing))
                                .frame(width: rowsIn ? max(6, g.size.width * CGFloat(p.turns) / CGFloat(top)) : 6)
                                .animation(.easeOut(duration: 0.7).delay(0.08 + Double(i) * 0.06), value: rowsIn)
                        }.frame(height: 8)
                        Text("\(p.turns)").font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(Ink.dim)
                            .frame(width: 44, alignment: .trailing)
                    }
                    .padding(.horizontal, 12).frame(height: Self.projRowH)
                }
            }
        }
    }

    // MARK: shared pieces

    private func list(_ items: [AgentSummary], height: CGFloat, selectable: Bool) -> some View {
        VStack(spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, r in
                row(r, selected: selectable && i == a.recallIndex, height: height)
                    .opacity(rowsIn ? 1 : 0).offset(y: rowsIn ? 0 : 7)
                    .animation(.easeOut(duration: 0.38).delay(Double(i) * 0.045), value: rowsIn)
                    .onTapGesture(count: 2) { a.recallIndex = i; a.openSelectedNote() }
                    .onTapGesture { a.recallIndex = i; a.moveSelection(0) }
            }
        }
    }

    private func row(_ r: AgentSummary, selected: Bool, height: CGFloat) -> some View {
        HStack(spacing: 12) {
            Text(r.name).font(.system(size: 11, weight: .medium, design: .monospaced)).tracking(0.2)
                .foregroundStyle(r.state == "ok" ? Ink.ember : Ink.dim).frame(width: 84, alignment: .leading).lineLimit(1)
            VStack(alignment: .leading, spacing: 1) {
                Text(r.lastTitle).font(.system(size: 15)).foregroundStyle(selected ? Ink.text : Ink.text.opacity(0.82)).lineLimit(1)
                Text(r.lastProject + (r.sessions > 1 ? "  ·  \(r.sessions) sessions" : "")).font(.system(size: 11)).foregroundStyle(Ink.dim).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(Self.age(r.lastUpdated)).font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(Ink.dim)
        }
        .padding(.horizontal, 12).frame(height: height - 2)
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
            .font(.system(size: 15)).foregroundStyle(Ink.dim)
            .frame(maxWidth: .infinity, minHeight: Self.rowH, alignment: .leading).padding(.horizontal, 12)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Ink.text.opacity(0.08)).frame(height: 1).padding(.bottom, 9)
            Text(a.summary.isEmpty ? "summarising…" : a.summary)
                .font(.system(size: 14)).lineSpacing(3)
                .foregroundStyle(a.summary.isEmpty ? Ink.dim : Ink.text).lineLimit(4)
        }
        .padding(.horizontal, 12).padding(.top, 6).frame(height: Self.summaryH, alignment: .top).clipped()
    }

    private var footerHints: [(String, String)] {
        switch a.page {
        case .chats: return [("↑↓", "move"), ("↩", "open"), ("⌘↩", "summarize"), ("/", "search"), ("⇥", "page")]
        case .activity: return [("←→", "day"), ("↑↓", "session"), ("↩", "open"), ("⌘↩", "summarize"), ("⇥", "page")]
        case .projects: return [("←→ ⇥", "page")]
        }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            ForEach(footerHints, id: \.0) { k, l in
                HStack(spacing: 5) { Text(k).foregroundStyle(Ink.text.opacity(0.75)); Text(l).foregroundStyle(Ink.dim) }
            }
            Spacer()
        }
        .font(.system(size: 11, weight: .medium)).tracking(0.3).padding(.horizontal, 12)
    }
}

/// One row of cells per agent, one column per day. Busy days glow ember; a sweep reveals it left to right.
private struct Heatmap: View {
    let grid: ActivityGrid
    let cursor: Int
    let start: Date
    let onPick: (Int) -> Void
    private static let labelW: CGFloat = 92, rowH: CGFloat = 22

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: Date().timeIntervalSince(start) > 1.6)) { ctx in
                Canvas { gc, size in draw(&gc, size, min(1, ctx.date.timeIntervalSince(start) / 0.9)) }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                let cw = (geo.size.width - Self.labelW) / CGFloat(max(grid.days.count, 1))
                if v.location.x >= Self.labelW { onPick(Int((v.location.x - Self.labelW) / cw)) }
            })
        }
    }

    private func draw(_ gc: inout GraphicsContext, _ size: CGSize, _ p: Double) {
        let n = grid.days.count
        guard n > 0 else { return }
        let cw = (size.width - Self.labelW) / CGFloat(n)
        let rowsH = CGFloat(grid.agents.count) * Self.rowH
        // selected day: a soft column behind the cells
        let colX = Self.labelW + CGFloat(cursor) * cw
        gc.fill(Path(roundedRect: CGRect(x: colX - 1, y: 0, width: cw + 1, height: rowsH), cornerRadius: 3), with: .color(Ink.text.opacity(0.07)))
        for (r, agent) in grid.agents.enumerated() {
            gc.draw(Text(agent).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundColor(Ink.dim),
                    at: CGPoint(x: 0, y: CGFloat(r) * Self.rowH + Self.rowH / 2), anchor: .leading)
            for i in 0..<n {
                let c = grid.cells[agent]?[i] ?? 0
                let reveal = min(1, max(0, (p * Double(n + 12) - Double(i)) / 12))
                let rect = CGRect(x: Self.labelW + CGFloat(i) * cw + 0.5, y: CGFloat(r) * Self.rowH + 3, width: max(cw - 1.4, 1), height: Self.rowH - 6)
                let color: Color = c == 0 ? Ink.text.opacity(0.07)
                    : Ink.ember.opacity(0.2 + 0.8 * pow(Double(c) / Double(max(grid.maxCount, 1)), 0.6))
                gc.opacity = reveal
                gc.fill(Path(roundedRect: rect, cornerRadius: 1.8), with: .color(color))
            }
            gc.opacity = 1
        }
        // selected day outline + month labels
        gc.stroke(Path(roundedRect: CGRect(x: colX - 1, y: 0, width: cw + 1, height: rowsH), cornerRadius: 3), with: .color(Ink.ember.opacity(0.85)), lineWidth: 1)
        let cal = Calendar.current
        for (i, d) in grid.days.enumerated() where i == 0 || cal.component(.day, from: d) == 1 {
            let f = DateFormatter(); f.dateFormat = "MMM"
            gc.draw(Text(f.string(from: d)).font(.system(size: 10, weight: .medium)).foregroundColor(Ink.dim),
                    at: CGPoint(x: Self.labelW + CGFloat(i) * cw, y: rowsH + 11), anchor: .leading)
        }
    }
}
