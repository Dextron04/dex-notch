import Foundation
import CoreGraphics

/// Pure helpers for "ask about my screen": the prompt wrapper, `<mark x y w h>label</mark>` parsing, and image-pixel → screen-point mapping.
enum ScreenMarks {
    /// `rect` in screenshot pixels, origin top-left. `label` is the note shown in the bubble. `bubble` is the top-left of the empty region the model picked for it (same pixels).
    struct Mark: Equatable { var rect: CGRect; var label: String; var bubble: CGPoint? = nil }
    static let maxMarks = 6
    /// Sent when the eye is on and nothing was typed.
    static let defaultQuestion = "Look at my screen, work out what I'm doing and what I probably need help with, and help. Point at the relevant spots."

    /// Plain-words trigger: saying "my screen" in so many words is a request to look. Explicit phrases only, so ordinary questions never capture.
    static func wantsScreen(_ prompt: String) -> Bool {
        prompt.range(of: #"\b(?:on|see|look at|what'?s on) my screen\b|\bmy screen\b|\bon screen\b|\bwhat am i looking at\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// What the model is told. Claude reads the PNG with its Read tool; Codex gets it with `-i`, so only the first line differs.
    static func prompt(_ question: String, path: String, size: CGSize, claude: Bool) -> String {
        let px = "\(Int(size.width))×\(Int(size.height)) px"
        let look = claude ? "The user's screen is in \(path) (\(px)). Read it first." : "The user's screen is attached as an image (\(px))."
        return look + "\n\n" + question + "\n\n" + markSyntax
    }

    /// The mark instructions every backend gets (Claude and Codex prompt, the look_at_screen hint, and the Both judge reuse the same words).
    static let markSyntax = "To point at something on the screen, write <mark x=\"\" y=\"\" w=\"\" h=\"\" bx=\"\" by=\"\">note</mark> using pixel coordinates in the screenshot (origin top-left). x y w h is the box around the thing. The note is shown to the user in a speech bubble on their screen, so keep it to one or two short sentences. bx by is the top-left corner of a blank area (plain background or whitespace, about 260×80 px) next to it where that bubble goes: look at the screenshot and pick real empty space, never on top of text, images or controls, and never in the top-centre where the notch is. Use at most \(maxMarks) marks. Only mark things you can actually see. Marks are removed from your text, so write sentences that read fine without them."

    private static let element = try! NSRegularExpression(pattern: #"<mark\b([^>]*)>(.*?)</mark\s*>"#, options: [.dotMatchesLineSeparators, .caseInsensitive])
    private static let attr = try! NSRegularExpression(pattern: #"\b([a-z]+)\s*=\s*["']?\s*(-?[0-9]*\.?[0-9]+)"#, options: [.caseInsensitive])
    private static let closer = try! NSRegularExpression(pattern: #"[ \t]*</mark\s*>"#, options: [.caseInsensitive])
    private static let openTag = try! NSRegularExpression(pattern: #"<mark(?:\s|$)"#, options: [.caseInsensitive])

    /// The text without mark tags, and the well-formed marks clamped to `imageSize` (zero = no clamp). Text with no `<mark` comes back untouched.
    /// While `streaming`, an unfinished tag at the end is hidden so it never flashes in the notch; final text is never truncated.
    /// `badges`: leave a ①…⑥ where each mark was, matching the numbers on the overlay, so the text points at the screen too.
    static func parse(_ text: String, imageSize: CGSize = .zero, streaming: Bool = false, badges: Bool = false) -> (clean: String, marks: [Mark]) {
        var text = text
        if streaming {
            if let m = openTag.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).last, let r = Range(m.range, in: text),
               text.range(of: "</mark", options: .caseInsensitive, range: r.upperBound..<text.endIndex) == nil { text = String(text[..<r.lowerBound]) }   // opened, not closed yet
            else if let lt = text.lastIndex(of: "<"), "<mark".hasPrefix(text[lt...].lowercased()) { text = String(text[..<lt]) }                          // "<", "<ma", …
        }
        guard text.range(of: "<mark", options: .caseInsensitive) != nil || text.range(of: "</mark", options: .caseInsensitive) != nil else {
            return (streaming ? text.replacingOccurrences(of: #"\s+\z"#, with: "", options: .regularExpression) : text, [])
        }
        var marks: [Mark] = []
        let ns = text as NSString
        var out = "", last = 0, seam = false
        func append(_ chunk: String) {
            var c = Substring(chunk)
            if seam, out.isEmpty || out.last == " " || out.last == "\t" || out.last == "\n" { c = c.drop { $0 == " " || $0 == "\t" } }   // tidy only where a tag was removed
            out += c; seam = false
        }
        for m in element.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            append(ns.substring(with: NSRange(location: last, length: m.range.location - last))); last = m.range.location + m.range.length
            guard marks.count < maxMarks, let r = rect(ns.substring(with: m.range(at: 1)), clamp: imageSize) else { seam = true; continue }   // malformed or over the cap: stripped anyway
            marks.append(Mark(rect: r.rect, label: ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines), bubble: r.bubble))
            if badges, let b = UnicodeScalar(0x245F + marks.count) { out += String(Character(b)); seam = false } else { seam = true }
        }
        append(ns.substring(from: last))
        out = closer.stringByReplacingMatches(in: out, range: NSRange(location: 0, length: (out as NSString).length), withTemplate: "")
        return (out.replacingOccurrences(of: #"\A\n+|\s+\z"#, with: "", options: .regularExpression), marks)
    }

    private static func rect(_ attrs: String, clamp size: CGSize) -> (rect: CGRect, bubble: CGPoint?)? {
        var v: [String: CGFloat] = [:]
        let ns = attrs as NSString
        for m in attr.matches(in: attrs, range: NSRange(location: 0, length: ns.length)) {
            if let d = Double(ns.substring(with: m.range(at: 2))) { v[ns.substring(with: m.range(at: 1)).lowercased()] = CGFloat(d) }
        }
        guard let x = v["x"], let y = v["y"], let w = v["w"], let h = v["h"], w > 0, h > 0 else { return nil }
        var r = CGRect(x: x, y: y, width: w, height: h)
        if size != .zero { r = r.intersection(CGRect(origin: .zero, size: size)) }
        guard !r.isNull, !r.isEmpty else { return nil }
        var b: CGPoint?
        if let bx = v["bx"], let by = v["by"] {      // both or neither; clamped into the image, and a nonsense anchor just means "place it yourself"
            b = size == .zero ? CGPoint(x: bx, y: by) : (CGRect(origin: .zero, size: size).contains(CGPoint(x: bx, y: by)) ? CGPoint(x: bx, y: by) : nil)
        }
        return (r, b)
    }

    // MARK: bubble placement (pure; local top-left points)

    /// How big a bubble for `note` is drawn: the view uses exactly this, so placement and drawing agree.
    static func bubbleSize(_ note: String) -> CGSize {
        let w = min(260, max(110, CGFloat(note.count) * 7 + 50))
        let lines = max(1, Int((CGFloat(note.count) * 6.8 / (w - 50)).rounded(.up)))
        return CGSize(width: w, height: CGFloat(min(lines, 5)) * 17 + 18)
    }

    /// Where each bubble goes, in the same local coordinates as `boxes`. A model-chosen `wanted` origin is used when it is clear;
    /// otherwise the sides of the box are tried, the one with the most room first. Never over a box, another bubble, an `avoid` rect (the notch), or outside `bounds`.
    static func placeBubbles(boxes: [CGRect], wanted: [CGPoint?], sizes: [CGSize], bounds: CGRect, avoid: [CGRect], gap: CGFloat = 14) -> [CGRect] {
        var blocked = boxes.map { $0.insetBy(dx: -4, dy: -4) } + avoid
        var out: [CGRect] = []
        for (i, b) in boxes.enumerated() {
            let sz = sizes[i]
            func fit(_ o: CGPoint) -> CGRect {
                CGRect(x: min(max(o.x, bounds.minX + 6), max(bounds.maxX - sz.width - 6, bounds.minX)), y: min(max(o.y, bounds.minY + 6), max(bounds.maxY - sz.height - 6, bounds.minY)), width: sz.width, height: sz.height)
            }
            let sides: [(room: CGFloat, at: CGPoint)] = [
                (bounds.maxX - b.maxX, CGPoint(x: b.maxX + gap, y: b.midY - sz.height / 2)),
                (b.minX - bounds.minX, CGPoint(x: b.minX - gap - sz.width, y: b.midY - sz.height / 2)),
                (bounds.maxY - b.maxY, CGPoint(x: b.midX - sz.width / 2, y: b.maxY + gap)),
                (b.minY - bounds.minY, CGPoint(x: b.midX - sz.width / 2, y: b.minY - gap - sz.height))]
            var cands: [CGRect] = []
            if let w = wanted[i] { cands.append(fit(w)) }
            cands += sides.sorted { $0.room > $1.room }.map { fit($0.at) }
            let ok = cands.first { c in !blocked.contains { $0.intersects(c.insetBy(dx: 1, dy: 1)) } && bounds.contains(c) }
            let pick = ok ?? cands.last ?? fit(b.origin)      // ponytail: nothing clear (a crowded screen): the roomiest side, overlapping rather than missing
            out.append(pick); blocked.append(pick.insetBy(dx: -6, dy: -6))
        }
        return out
    }

    static func toScreen(_ p: CGPoint, imageSize: CGSize, screenFrame f: CGRect) -> CGPoint {
        let r = toScreen(CGRect(origin: p, size: .zero), imageSize: imageSize, screenFrame: f); return CGPoint(x: r.minX, y: r.maxY)
    }

    /// Screenshot pixels (top-left origin) → AppKit global points (bottom-left origin) on the display `screenFrame` it was taken from.
    static func toScreen(_ r: CGRect, imageSize: CGSize, screenFrame f: CGRect) -> CGRect {
        let sx = f.width / imageSize.width, sy = f.height / imageSize.height
        return CGRect(x: f.minX + r.minX * sx, y: f.maxY - r.maxY * sy, width: r.width * sx, height: r.height * sy)
    }
}
