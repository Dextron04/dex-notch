import SwiftUI

// The dial's marks. Claude and Codex are the official logos (path data in OfficialMarks.swift, see NOTICE.md), drawn in their own
// colours and never recoloured; an unselected one is only dimmed. The local-model mark is this project's own.

/// An SVG path on a 24×24 grid, scaled to fit.
private struct GridShape: Shape {
    let path: Path
    func path(in r: CGRect) -> Path { path.applying(CGAffineTransform(scaleX: r.width / 24, y: r.height / 24)) }
}

/// Your own model: a rounded square with the notch cut into its top edge and a spark of light inside.
struct LocalMark: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path(); let s = min(r.width, r.height), box = CGRect(x: r.midX - 0.42 * s, y: r.midY - 0.42 * s, width: 0.84 * s, height: 0.84 * s)
        p.addRoundedRect(in: box, cornerSize: CGSize(width: 0.2 * s, height: 0.2 * s))
        p.move(to: CGPoint(x: r.midX - 0.13 * s, y: box.minY + 0.17 * s)); p.addLine(to: CGPoint(x: r.midX + 0.13 * s, y: box.minY + 0.17 * s))   // the notch
        p.addEllipse(in: CGRect(x: r.midX - 0.03 * s, y: r.midY + 0.10 * s, width: 0.06 * s, height: 0.06 * s))                                       // the spark
        return p
    }
}

struct ModelMark: View {
    private static let claude = SVGPath.parse(OfficialMarks.claude)
    private static let codex = SVGPath.parse(OfficialMarks.codex)
    private static let claudeOrange = Color(red: 0.851, green: 0.467, blue: 0.341)   // #D97757

    let backend: Backend
    var size: CGFloat = 17
    var active = true

    var body: some View {
        Group {
            switch backend {
            case .claude: GridShape(path: Self.claude).fill(Self.claudeOrange).opacity(active ? 1 : 0.5)
            case .codex: GridShape(path: Self.codex).fill(Color.white, style: FillStyle(eoFill: true)).opacity(active ? 1 : 0.5)
            case .gemma:
                LocalMark().stroke(active ? Ink.ember : Ink.dim, style: StrokeStyle(lineWidth: size * 0.11, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(backend.displayName)
    }
}

/// An add-on's own logo, in its own colours (never recoloured): Gmail and Outlook, plus a plain iPhone symbol.
struct AddonMark: View {
    private static let outlook = SVGPath.parse(OfficialMarks.outlook)
    private static let outlookBlue = Color(red: 0, green: 0.471, blue: 0.831)   // #0078D4
    private static let gmail = OfficialMarks.gmail.map { (Color(hex: $0.0), SVGPath.parse($0.1)) }
    let addon: String
    var size: CGFloat = 16      // width; Gmail's mark is 4:3
    static func name(_ addon: String) -> String { addon == "outlook" ? "Outlook" : addon == "phone" ? "iPhone" : addon == "mac" ? "Mac" : addon == "app" ? "Dex Notch" : "Gmail" }

    var body: some View {
        if addon == "outlook" { GridShape(path: Self.outlook).fill(Self.outlookBlue).frame(width: size, height: size).accessibilityLabel("Outlook") }
        else if addon == "app" { Image("AppMark").resizable().frame(width: size, height: size).accessibilityLabel("Dex Notch") }
        else if addon == "phone" || addon == "mac" { Image(systemName: addon == "mac" ? "laptopcomputer" : "iphone").font(.system(size: size * 0.9)).foregroundStyle(Ink.dim).frame(width: size, height: size * 0.75).accessibilityLabel("iPhone") }
        else { gmailMark }
    }

    private var gmailMark: some View {
        ZStack {
            ForEach(Self.gmail.indices, id: \.self) { i in
                GmailPiece(path: Self.gmail[i].1).fill(Self.gmail[i].0)
            }
        }
        .frame(width: size, height: size * 0.75)
        .accessibilityLabel("Gmail")
    }
}

private struct GmailPiece: Shape {
    let path: Path
    func path(in r: CGRect) -> Path { path.applying(CGAffineTransform(scaleX: r.width / 52, y: r.height / 39)) }
}

private extension Color {
    init(hex: String) {
        let v = UInt32(hex, radix: 16) ?? 0
        self.init(red: Double(v >> 16 & 255) / 255, green: Double(v >> 8 & 255) / 255, blue: Double(v & 255) / 255)
    }
}
