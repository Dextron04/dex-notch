import SwiftUI

// Simplified, original vector marks for the model dial. They are drawn (not bitmaps), so they tint with the theme
// (amber when selected, dim otherwise) and stay sharp at any size. They are not the brands' official artwork.

/// Claude: a sunburst of twelve rounded rays, long and short alternating.
struct ClaudeMark: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path(); let c = CGPoint(x: r.midX, y: r.midY), s = min(r.width, r.height)
        for k in 0..<12 {
            let a = Double(k) * .pi / 6 - .pi / 2
            let outer = (k % 2 == 0 ? 0.48 : 0.34) * s, inner = 0.10 * s
            p.move(to: CGPoint(x: c.x + cos(a) * inner, y: c.y + sin(a) * inner))
            p.addLine(to: CGPoint(x: c.x + cos(a) * outer, y: c.y + sin(a) * outer))
        }
        return p
    }
}

/// Codex: a hexagon with three spokes meeting at the centre.
struct CodexMark: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path(); let c = CGPoint(x: r.midX, y: r.midY), s = min(r.width, r.height), rad = 0.46 * s
        let v = (0..<6).map { k -> CGPoint in let a = Double(k) * .pi / 3 - .pi / 2; return CGPoint(x: c.x + cos(a) * rad, y: c.y + sin(a) * rad) }
        p.move(to: v[0]); for i in 1..<6 { p.addLine(to: v[i]) }; p.closeSubpath()
        for i in stride(from: 0, to: 6, by: 2) { p.move(to: c); p.addLine(to: v[i]) }
        return p
    }
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
    let backend: Backend
    var size: CGFloat = 17
    var body: some View {
        let style = StrokeStyle(lineWidth: size * 0.11, lineCap: .round, lineJoin: .round)
        Group {
            switch backend {
            case .claude: ClaudeMark().stroke(style: StrokeStyle(lineWidth: size * 0.13, lineCap: .round))
            case .codex: CodexMark().stroke(style: style)
            case .gemma: LocalMark().stroke(style: style)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(backend.displayName)
    }
}
