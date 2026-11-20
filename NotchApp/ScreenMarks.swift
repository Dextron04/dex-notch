import Foundation
import CoreGraphics

/// Pure helpers for "ask about my screen": the prompt wrapper, `<mark x y w h>label</mark>` parsing, and image-pixel → screen-point mapping.
enum ScreenMarks {
    struct Mark: Equatable { var rect: CGRect; var label: String }   // rect in screenshot pixels, origin top-left
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
        return look + "\n\n" + question + "\n\nTo point at something on the screen, write <mark x=\"\" y=\"\" w=\"\" h=\"\">short label</mark> using pixel coordinates in the screenshot (origin top-left). Use at most \(maxMarks) marks. Only mark things you can actually see. Marks are removed from your text, so write sentences that read fine without them."
    }

    private static let element = try! NSRegularExpression(pattern: #"<mark\b([^>]*)>(.*?)</mark\s*>"#, options: [.dotMatchesLineSeparators, .caseInsensitive])
    private static let attr = try! NSRegularExpression(pattern: #"\b([a-z]+)\s*=\s*["']?\s*(-?[0-9]*\.?[0-9]+)"#, options: [.caseInsensitive])
    private static let closer = try! NSRegularExpression(pattern: #"[ \t]*</mark\s*>"#, options: [.caseInsensitive])
    private static let openTag = try! NSRegularExpression(pattern: #"<mark(?:\s|$)"#, options: [.caseInsensitive])

    /// The text without mark tags, and the well-formed marks clamped to `imageSize` (zero = no clamp). Text with no `<mark` comes back untouched.
    /// While `streaming`, an unfinished tag at the end is hidden so it never flashes in the notch; final text is never truncated.
    static func parse(_ text: String, imageSize: CGSize = .zero, streaming: Bool = false) -> (clean: String, marks: [Mark]) {
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
            append(ns.substring(with: NSRange(location: last, length: m.range.location - last))); last = m.range.location + m.range.length; seam = true
            guard marks.count < maxMarks, let r = rect(ns.substring(with: m.range(at: 1)), clamp: imageSize) else { continue }   // malformed or over the cap: stripped anyway
            marks.append(Mark(rect: r, label: ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        append(ns.substring(from: last))
        out = closer.stringByReplacingMatches(in: out, range: NSRange(location: 0, length: (out as NSString).length), withTemplate: "")
        return (out.replacingOccurrences(of: #"\A\n+|\s+\z"#, with: "", options: .regularExpression), marks)
    }

    private static func rect(_ attrs: String, clamp size: CGSize) -> CGRect? {
        var v: [String: CGFloat] = [:]
        let ns = attrs as NSString
        for m in attr.matches(in: attrs, range: NSRange(location: 0, length: ns.length)) {
            if let d = Double(ns.substring(with: m.range(at: 2))) { v[ns.substring(with: m.range(at: 1)).lowercased()] = CGFloat(d) }
        }
        guard let x = v["x"], let y = v["y"], let w = v["w"], let h = v["h"], w > 0, h > 0 else { return nil }
        var r = CGRect(x: x, y: y, width: w, height: h)
        if size != .zero { r = r.intersection(CGRect(origin: .zero, size: size)) }
        return r.isNull || r.isEmpty ? nil : r
    }

    /// Screenshot pixels (top-left origin) → AppKit global points (bottom-left origin) on the display `screenFrame` it was taken from.
    static func toScreen(_ r: CGRect, imageSize: CGSize, screenFrame f: CGRect) -> CGRect {
        let sx = f.width / imageSize.width, sy = f.height / imageSize.height
        return CGRect(x: f.minX + r.minX * sx, y: f.maxY - r.maxY * sy, width: r.width * sx, height: r.height * sy)
    }
}
