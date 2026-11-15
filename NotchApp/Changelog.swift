import Foundation

/// Turns CHANGELOG.md into things the "What's new" panel can show, pictures and videos included.
/// The file is the single source: a release's notes are whatever its changelog sections say, with media paths resolved against that release's tag.
enum Changelog {
    enum Block: Equatable {
        case release(version: String, title: String)
        case date(String)
        case text(String)
        case bullet(String)
        case image(URL, alt: String)       // png, jpg or an animated gif
        case video(URL, title: String)
    }
    struct Section: Equatable { var version: String; var title: String; var body: String }

    // MARK: versions

    static func parts(_ v: String) -> [Int] { v.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: ".").map { Int($0) ?? 0 } }
    /// 0.10.0 > 0.9.0; missing parts count as zero.
    static func newer(_ a: String, than b: String) -> Bool {
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    // MARK: sections

    /// "## v0.5.0: Outlook and Microsoft 365 mail" starts a release. Everything before the first one (logo, intro) is dropped.
    static func sections(_ md: String) -> [Section] {
        var out: [Section] = [], cur: Section?
        func flush() { if let c = cur { out.append(c) } }
        for line in md.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("## "), let h = heading(String(line.dropFirst(3))) { flush(); cur = Section(version: h.version, title: h.title, body: ""); continue }
            if cur != nil { cur!.body += line + "\n" }
        }
        flush()
        return out
    }
    private static func heading(_ s: String) -> (version: String, title: String)? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard let f = t.first, f == "v" || f.isNumber else { return nil }
        let rest = t.drop { $0 != ":" && $0 != " " }
        let ver = String(t.prefix(t.count - rest.count))
        guard parts(ver).contains(where: { $0 > 0 }) || ver.contains(".") else { return nil }
        return (ver.trimmingCharacters(in: CharacterSet(charactersIn: "vV")), rest.drop { $0 == ":" || $0 == " " }.description)
    }

    /// Every release you don't have yet, newest first, up to and including `new`.
    static func missed(_ md: String, installed: String, upTo new: String) -> [Section] {
        sections(md).filter { newer($0.version, than: installed) && !newer($0.version, than: new) }
    }

    // MARK: blocks

    static func blocks(_ sections: [Section], base: URL) -> [Block] {
        sections.flatMap { [Block.release(version: $0.version, title: $0.title)] + blocks($0.body, base: base) }
    }

    static func blocks(_ body: String, base: URL) -> [Block] {
        var out: [Block] = []
        for raw in body.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("<p") || line.hasPrefix("</p") || line == "---" { continue }
            if line.hasPrefix("<img") {
                if let src = attr("src", in: line), let u = resolve(src, base) { out.append(.image(u, alt: attr("alt", in: line) ?? "")) }
                continue
            }
            if line.hasPrefix("!["), let (alt, path) = link(line), let u = resolve(path, base) { out.append(.image(u, alt: alt)); continue }
            if line.hasPrefix("["), let (title, path) = link(line), ["mp4", "mov", "m4v"].contains((path as NSString).pathExtension.lowercased()), let u = resolve(path, base) {
                out.append(.video(u, title: title)); continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") && !line.hasSuffix("*") { out.append(.bullet(String(line.dropFirst(2)))); continue }
            if line.hasPrefix("*"), line.hasSuffix("*"), !line.hasPrefix("**") { out.append(.date(line.trimmingCharacters(in: CharacterSet(charactersIn: "*")))); continue }
            out.append(.text(line))
        }
        return out
    }

    private static func attr(_ name: String, in tag: String) -> String? {
        guard let r = tag.range(of: name + "=\"") else { return nil }
        let rest = tag[r.upperBound...]
        return rest.firstIndex(of: "\"").map { String(rest[..<$0]) }
    }
    /// "[text](path)" or "![alt](path)" alone on a line.
    private static func link(_ line: String) -> (String, String)? {
        guard let a = line.firstIndex(of: "["), let b = line.firstIndex(of: "]"), let c = line.range(of: "](")?.upperBound, let d = line.lastIndex(of: ")"), a < b, c <= d else { return nil }
        return (String(line[line.index(after: a)..<b]), String(line[c..<d]))
    }
    /// Absolute links stay; paths in the repo (docs/assets/x.gif) are read from the same tag as the notes. `base` ends in "/".
    static func resolve(_ path: String, _ base: URL) -> URL? {
        if path.hasPrefix("http://") || path.hasPrefix("https://") { return URL(string: path) }
        return URL(string: path.hasPrefix("/") ? String(path.dropFirst()) : path, relativeTo: base)?.absoluteURL
    }

    // MARK: loading

    static let repo = "Dextron04/dex-notch"

    /// The notes for every release between what you run and `new`. $NOTCH_CHANGELOG_DIR reads a local checkout instead (demos, screenshots).
    static func load(installed: String, new: String) async -> [Block]? {
        if let d = ProcessInfo.processInfo.environment["NOTCH_CHANGELOG_DIR"], !d.isEmpty {
            let dir = URL(fileURLWithPath: d, isDirectory: true)
            guard let md = try? String(contentsOf: dir.appendingPathComponent("CHANGELOG.md"), encoding: .utf8) else { return nil }
            return blocks(missed(md, installed: installed, upTo: new), base: dir)
        }
        for ref in ["v\(new)", "main"] {
            guard let base = URL(string: "https://raw.githubusercontent.com/\(repo)/\(ref)/"),
                  let (data, resp) = try? await URLSession.shared.data(from: base.appendingPathComponent("CHANGELOG.md")),
                  (resp as? HTTPURLResponse)?.statusCode == 200, let md = String(data: data, encoding: .utf8) else { continue }
            let found = missed(md, installed: installed, upTo: new)
            if !found.isEmpty { return blocks(found, base: base) }
        }
        return nil
    }
}
