import SwiftUI

/// Renders a model answer: prose as serif text, fenced code as a lifted mono block with
/// language label, copy button and light syntax colour. Handles a fence that is still streaming.
struct AnswerBody: View {
    let text: String

    private enum Block { case prose(String), code(lang: String, body: String) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                switch b {
                case .prose(let s):
                    Text(Self.prose(s))
                        .font(.system(size: 16.5, design: .serif)).lineSpacing(4)
                        .foregroundStyle(Ink.text).textSelection(.enabled)
                case .code(let lang, let code):
                    CodeBlock(lang: lang, code: code)
                }
            }
        }
    }

    // MARK: parsing

    private var blocks: [Block] {
        var out: [Block] = [], buf: [Substring] = [], lang: String?
        func flush() {
            let s = buf.joined(separator: "\n"); buf = []
            if let l = lang { out.append(.code(lang: l, body: s)) }
            else if !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                out.append(.prose(s.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if lang == nil { flush(); lang = line.trimmingCharacters(in: .whitespaces).dropFirst(3).trimmingCharacters(in: .whitespaces) }
                else { flush(); lang = nil } // closing fence
            } else { buf.append(line) }
        }
        flush() // unclosed fence = code still streaming; renders as code immediately
        return out
    }

    /// Inline markdown, with `code` spans in ember mono.
    static func prose(_ s: String) -> AttributedString {
        var a = (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
        for run in a.runs where run.inlinePresentationIntent?.contains(.code) == true {
            a[run.range].font = .system(size: 14.5, design: .monospaced)
            a[run.range].foregroundColor = Ink.ember
        }
        return a
    }
}

private struct CodeBlock: View {
    let lang: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(lang.isEmpty ? "code" : lang.lowercased())
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced)).tracking(0.4)
                    .foregroundStyle(Ink.dim)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.3)); copied = false }
                } label: {
                    Text(copied ? "copied" : "copy")
                        .font(.system(size: 10.5, weight: .medium)).tracking(0.3)
                        .foregroundStyle(copied ? Ink.ember : Ink.dim)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14).padding(.top, 9).padding(.bottom, 5)

            ScrollView(.horizontal) {
                Text(Highlight.run(code))
                    .font(.system(size: 13, design: .monospaced)).lineSpacing(3)
                    .fixedSize() // no wrapping: long lines scroll sideways instead of breaking code
                    .padding(.horizontal, 14).padding(.bottom, 12).padding(.top, 2)
                    .textSelection(.enabled)
            }
            .scrollIndicators(.never)
            .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.94), .init(color: .clear, location: 1)],
                                 startPoint: .leading, endPoint: .trailing)) // hints that long lines scroll sideways
        }
        .background(Ink.text.opacity(0.065), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Ink.text.opacity(0.07), lineWidth: 1))
    }
}

/// Deliberately tiny, language-agnostic highlighter: keywords, numbers, strings, comments.
// ponytail: regex heuristics, not a parser. Swap in tree-sitter/Highlightr if languages start looking wrong.
private enum Highlight {
    static let rules: [(NSRegularExpression, Color)] = {
        let kw = "func|fn|def|class|struct|enum|protocol|interface|impl|trait|let|var|const|val|mut|if|else|elif|guard|switch|case|match|for|while|loop|in|of|return|yield|break|continue|import|from|use|package|module|export|public|private|static|final|async|await|try|catch|except|throw|throws|raise|new|self|this|super|None|nil|null|true|false|True|False|and|or|not|is|with|as|where|type|extends|implements"
        let sage = Color(red: 0.62, green: 0.78, blue: 0.58)
        let sand = Color(red: 0.86, green: 0.76, blue: 0.55)
        let list: [(String, Color, NSRegularExpression.Options)] = [
            ("\\b(\(kw))\\b", Ink.ember, []),
            ("\\b\\d+(\\.\\d+)?\\b", sand, []),
            ("\"(\\\\.|[^\"\\\\\\n])*\"|'(\\\\.|[^'\\\\\\n])*'|`[^`\\n]*`", sage, []),
            ("(//|#)[^\\n]*|/\\*[\\s\\S]*?(\\*/|$)", Ink.dim, []),
        ]
        return list.compactMap { p, c, o in (try? NSRegularExpression(pattern: p, options: o)).map { ($0, c) } }
    }()

    static func run(_ code: String) -> AttributedString {
        var a = AttributedString(code)
        a.foregroundColor = Ink.text
        let ns = code as NSString
        for (re, color) in rules { // later rules (strings, comments) win over earlier ones
            for m in re.matches(in: code, range: NSRange(location: 0, length: ns.length)) {
                guard let r = Range(m.range, in: code) else { continue }
                let lo = a.index(a.startIndex, offsetByCharacters: code.distance(from: code.startIndex, to: r.lowerBound))
                let hi = a.index(lo, offsetByCharacters: code.distance(from: r.lowerBound, to: r.upperBound))
                a[lo..<hi].foregroundColor = color
            }
        }
        return a
    }
}
