import SwiftUI

/// ⌘Y: every conversation had here, newest first, kept on this Mac only. ↑↓ move, ↩ resume, ⌘⌫ delete (press twice), esc back to the chat.
struct HistoryView: View {
    @Bindable var a: Assistant
    static let rowH: CGFloat = 46
    private static let headerH: CGFloat = 44, footerH: CGFloat = 36, groupH: CGFloat = 24
    private static let minList: CGFloat = 92, maxList: CGFloat = 6 * rowH + groupH
    @FocusState private var searchFocus: Bool
    @State private var rowsIn = false
    @Environment(\.accessibilityReduceMotion) private var reduce

    /// Height under the wings: search, the list (as tall as its rows, within bounds), hints.
    static func bodyHeight(_ a: Assistant) -> CGFloat {
        let groups = HistoryStore.grouped(a.historyShown)
        let rows = CGFloat(groups.reduce(0) { $0 + $1.items.count }) * rowH + CGFloat(groups.count) * groupH
        return headerH + min(max(rows, minList), maxList) + footerH
    }

    var body: some View {
        let groups = HistoryStore.grouped(a.historyShown)
        VStack(spacing: 0) {
            header.frame(height: Self.headerH)
            if groups.isEmpty { empty.frame(height: Self.bodyHeight(a) - Self.headerH - Self.footerH) } else { list(groups) }
            footer.frame(height: Self.footerH)
        }
        .padding(.horizontal, 18)
        .task { searchFocus = true; await Task.yield(); searchFocus = true }
        .task(id: a.isOpen && a.mode == .history) { rowsIn = false; try? await Task.sleep(for: .milliseconds(60)); rowsIn = true }
    }

    private var header: some View {
        HStack(spacing: 10) {
            TextField("", text: $a.historyQuery, prompt: Text("Search conversations").foregroundStyle(Ink.dim))
                .textFieldStyle(.plain).font(.system(size: 18)).foregroundStyle(Ink.text).tint(Ink.ember).focused($searchFocus)
            Text("\(a.historyShown.count)").font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(Ink.dim)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 12)
        .animation(.snappy(duration: 0.15), value: a.historyShown.count)
    }

    private func list(_ groups: [(label: String, items: [SavedConversation])]) -> some View {
        let flat = a.historyShown
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(groups, id: \.label) { g in
                        Text(g.label.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.8).foregroundStyle(Ink.dim)
                            .frame(maxWidth: .infinity, minHeight: Self.groupH - 2, alignment: .bottomLeading).padding(.horizontal, 12).padding(.bottom, 3)
                        ForEach(g.items, id: \.id) { c in
                            let i = flat.firstIndex { $0.id == c.id } ?? 0
                            row(c, selected: i == a.historyIndex, order: i)
                                .id(c.id)
                                .onTapGesture(count: 2) { a.resume(c.id ?? "") }
                                .onTapGesture { a.historyIndex = i; a.pendingDelete = nil }
                        }
                    }
                }
                .padding(.bottom, 2)
            }
            .scrollIndicators(.never)
            .onChange(of: a.historyIndex) { _, i in if flat.indices.contains(i) { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(flat[i].id) } } }
            .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.93), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
        }
    }

    private func row(_ c: SavedConversation, selected: Bool, order: Int) -> some View {
        let arming = a.pendingDelete != nil && a.pendingDelete == c.id
        let snippet = c.turns.last(where: { $0.role == "assistant" && !$0.text.isEmpty })?.text.split(whereSeparator: \.isWhitespace).joined(separator: " ") ?? ""
        return HStack(spacing: 12) {
            ModelMark(backend: c.backend, size: 16, active: selected).frame(width: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(c.title ?? HistoryStore.title(c.turns)).font(.system(size: 15)).foregroundStyle(selected ? Ink.text : Ink.text.opacity(0.82)).lineLimit(1)
                Text(arming ? "Press ⌘⌫ again to delete this conversation" : snippet.isEmpty ? "No answer yet" : snippet)
                    .font(.system(size: 11)).foregroundStyle(arming ? Ink.emberDeep : Ink.dim).lineLimit(1)
            }
            Spacer(minLength: 8)
            if c.id == a.openID { Circle().fill(Ink.ember).frame(width: 4, height: 4).accessibilityLabel("Open now") }
            if (c.vaultTurns ?? 0) > 0 {
                Image(systemName: "tray.full").font(.system(size: 10.5)).foregroundStyle(Ink.ember.opacity(0.8)).help("Saved to your vault").accessibilityLabel("Saved to vault")
            }
            Text(RecallView.age(c.activity)).font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(Ink.dim)
                .frame(minWidth: 26, alignment: .trailing)
        }
        .padding(.horizontal, 12).frame(height: Self.rowH - 2)
        .background(selected ? Ink.text.opacity(arming ? 0.11 : 0.075) : .clear, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .contentShape(Rectangle())
        .opacity(rowsIn || reduce ? 1 : 0).offset(y: rowsIn || reduce ? 0 : 7)
        .animation(.easeOut(duration: 0.34).delay(Double(min(order, 8)) * 0.04), value: rowsIn)
        .animation(.easeOut(duration: 0.14), value: selected)
        .transition(.opacity)
    }

    private var empty: some View {
        let searching = !a.historyQuery.trimmingCharacters(in: .whitespaces).isEmpty
        return VStack(alignment: .leading, spacing: 6) {
            Text(searching ? "Nothing matches “\(a.historyQuery)”." : "No conversations yet.").font(.system(size: 21, weight: .semibold)).foregroundStyle(Ink.text)
            Text(searching ? "Search looks at titles and every message." : "What you ask here is kept on this Mac, so you can pick it up later. Nothing goes to your vault unless you save it with ⌘S.")
                .font(.system(size: 13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading).padding(.horizontal, 12)
    }

    private var hints: [(String, String)] { [("↑↓", "move"), ("↩", "resume"), ("⌘⌫", "delete"), ("esc", "back")] }

    private var footer: some View {
        HStack(spacing: 16) {
            ForEach(hints, id: \.0) { k, l in
                HStack(spacing: 5) { Text(k).foregroundStyle(Ink.text.opacity(0.75)); Text(l).foregroundStyle(Ink.dim) }
            }
            Spacer()
        }
        .font(.system(size: 11, weight: .medium)).tracking(0.3).padding(.horizontal, 12)
    }
}
