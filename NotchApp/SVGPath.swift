import SwiftUI

/// Reads SVG path data (the `d` attribute) into a SwiftUI Path.
/// Supports M L H V C S Q T A Z in absolute and relative form, implicit repeats, and the compact number forms SVG allows
/// (".5.5", "1-2", "1e1", packed arc flags like "0110 0"). Malformed data yields whatever was valid up to that point.
enum SVGPath {
    static func parse(_ d: String) -> Path {
        var r = Reader(Array(d.unicodeScalars))
        var path = Path()
        var cur = CGPoint.zero, start = CGPoint.zero
        var lastCubic: CGPoint?, lastQuad: CGPoint?      // previous control point, for S and T reflection
        var cmd: Character = " "

        func pt(_ x: Double, _ y: Double, rel: Bool) -> CGPoint { rel ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y) }

        while true {
            r.skipSeparators()
            if r.atEnd { break }
            if let c = r.peekCommand() { cmd = c; r.advance() }
            else if cmd == " " || "Zz".contains(cmd) { break }            // numbers with no command to apply them to
            let rel = cmd.isLowercase
            let up = Character(cmd.uppercased())

            switch up {
            case "Z":
                path.closeSubpath(); cur = start; lastCubic = nil; lastQuad = nil
                continue
            case "M":
                guard let x = r.number(), let y = r.number() else { return path }
                cur = pt(x, y, rel: rel); start = cur; path.move(to: cur)
                cmd = rel ? "l" : "L"                                        // further pairs after a moveto are linetos
                lastCubic = nil; lastQuad = nil
            case "L":
                guard let x = r.number(), let y = r.number() else { return path }
                cur = pt(x, y, rel: rel); path.addLine(to: cur); lastCubic = nil; lastQuad = nil
            case "H":
                guard let x = r.number() else { return path }
                cur = CGPoint(x: rel ? cur.x + x : x, y: cur.y); path.addLine(to: cur); lastCubic = nil; lastQuad = nil
            case "V":
                guard let y = r.number() else { return path }
                cur = CGPoint(x: cur.x, y: rel ? cur.y + y : y); path.addLine(to: cur); lastCubic = nil; lastQuad = nil
            case "C":
                guard let a = r.number(), let b = r.number(), let c = r.number(), let d = r.number(), let x = r.number(), let y = r.number() else { return path }
                let c1 = pt(a, b, rel: rel), c2 = pt(c, d, rel: rel), end = pt(x, y, rel: rel)
                path.addCurve(to: end, control1: c1, control2: c2); lastCubic = c2; lastQuad = nil; cur = end
            case "S":
                guard let c = r.number(), let d = r.number(), let x = r.number(), let y = r.number() else { return path }
                let c1 = lastCubic.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                let c2 = pt(c, d, rel: rel), end = pt(x, y, rel: rel)
                path.addCurve(to: end, control1: c1, control2: c2); lastCubic = c2; lastQuad = nil; cur = end
            case "Q":
                guard let a = r.number(), let b = r.number(), let x = r.number(), let y = r.number() else { return path }
                let c = pt(a, b, rel: rel), end = pt(x, y, rel: rel)
                path.addQuadCurve(to: end, control: c); lastQuad = c; lastCubic = nil; cur = end
            case "T":
                guard let x = r.number(), let y = r.number() else { return path }
                let c = lastQuad.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                let end = pt(x, y, rel: rel)
                path.addQuadCurve(to: end, control: c); lastQuad = c; lastCubic = nil; cur = end
            case "A":
                guard let rx = r.number(), let ry = r.number(), let rot = r.number(), let large = r.flag(), let sweep = r.flag(),
                      let x = r.number(), let y = r.number() else { return path }
                let end = pt(x, y, rel: rel)
                addArc(&path, from: cur, rx: rx, ry: ry, rotation: rot, large: large, sweep: sweep, to: end)
                cur = end; lastCubic = nil; lastQuad = nil
            default:
                return path                                                  // an unknown command: stop here
            }
        }
        return path
    }

    // MARK: arcs (SVG spec, appendix F.6: endpoint to centre parameterisation, then cubic segments of at most 90°)

    private static func addArc(_ p: inout Path, from p0: CGPoint, rx rx0: Double, ry ry0: Double, rotation: Double, large: Bool, sweep: Bool, to p1: CGPoint) {
        var rx = abs(rx0), ry = abs(ry0)
        if p0 == p1 { return }
        if rx == 0 || ry == 0 { p.addLine(to: p1); return }
        let phi = rotation * .pi / 180, cosP = cos(phi), sinP = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1 = cosP * dx + sinP * dy, y1 = -sinP * dx + cosP * dy
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 { let s = lambda.squareRoot(); rx *= s; ry *= s }          // radii too small: scale up until the arc fits
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var coef = den == 0 ? 0 : max(0, num / den).squareRoot()
        if large == sweep { coef = -coef }
        let cxp = coef * rx * y1 / ry, cyp = -coef * ry * x1 / rx
        let cx = cosP * cxp - sinP * cyp + (p0.x + p1.x) / 2, cy = sinP * cxp + cosP * cyp + (p0.y + p1.y) / 2
        func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double { atan2(ux * vy - uy * vx, ux * vx + uy * vy) }
        let ux = (x1 - cxp) / rx, uy = (y1 - cyp) / ry, vx = (-x1 - cxp) / rx, vy = (-y1 - cyp) / ry
        let theta = angle(1, 0, ux, uy)
        var delta = angle(ux, uy, vx, vy)
        if !sweep && delta > 0 { delta -= 2 * .pi } else if sweep && delta < 0 { delta += 2 * .pi }
        let n = max(1, Int((abs(delta) / (.pi / 2)).rounded(.up)))
        let step = delta / Double(n), k = 4.0 / 3.0 * tan(step / 4)
        func map(_ u: Double, _ v: Double) -> CGPoint {
            CGPoint(x: cx + rx * cosP * u - ry * sinP * v, y: cy + rx * sinP * u + ry * cosP * v)
        }
        var a = theta
        for _ in 0..<n {
            let b = a + step
            p.addCurve(to: map(cos(b), sin(b)),
                       control1: map(cos(a) - k * sin(a), sin(a) + k * cos(a)),
                       control2: map(cos(b) + k * sin(b), sin(b) - k * cos(b)))
            a = b
        }
    }

    // MARK: tokenising

    private struct Reader {
        let s: [Unicode.Scalar]; var i = 0
        init(_ s: [Unicode.Scalar]) { self.s = s }
        var atEnd: Bool { i >= s.count }
        mutating func advance() { i += 1 }
        mutating func skipSeparators() { while i < s.count, s[i] == " " || s[i] == "," || s[i] == "\n" || s[i] == "\t" || s[i] == "\r" { i += 1 } }
        func peekCommand() -> Character? {
            guard i < s.count else { return nil }
            let c = Character(s[i])
            return "MmLlHhVvCcSsQqTtAaZz".contains(c) ? c : nil
        }
        /// A single arc flag: exactly one "0" or "1", which SVG lets run straight into the next number.
        mutating func flag() -> Bool? {
            skipSeparators()
            guard i < s.count, s[i] == "0" || s[i] == "1" else { return nil }
            defer { i += 1 }
            return s[i] == "1"
        }
        mutating func number() -> Double? {
            skipSeparators()
            let begin = i
            if i < s.count, s[i] == "+" || s[i] == "-" { i += 1 }
            var digits = 0
            while i < s.count, s[i].properties.numericType != nil, s[i].isASCII { i += 1; digits += 1 }
            if i < s.count, s[i] == "." {
                i += 1
                while i < s.count, s[i].properties.numericType != nil, s[i].isASCII { i += 1; digits += 1 }
            }
            guard digits > 0 else { i = begin; return nil }
            if i < s.count, s[i] == "e" || s[i] == "E" {
                let save = i; i += 1
                if i < s.count, s[i] == "+" || s[i] == "-" { i += 1 }
                var exp = 0
                while i < s.count, s[i].isASCII, s[i].properties.numericType != nil { i += 1; exp += 1 }
                if exp == 0 { i = save }
            }
            return Double(String(String.UnicodeScalarView(s[begin..<i])))
        }
    }
}
