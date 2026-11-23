import Foundation

struct JournalEntry: Equatable { var role: String; var text: String; var ts: Date }

enum Journal {
    static var defaultDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NotchApp/journal")
    }
    static func safeName(_ id: String) -> String { String(id.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }) }
    /// Appends a chat the user chose to save to `<dir>/<conv>.jsonl` — the file the recorder's `notch` adapter turns into a vault note.
    /// One line per entry; O_APPEND so a crash leaves whole lines or none; mode 0600 (chat text is private).
    static func append(_ entries: [JournalEntry], conv: String, model: String, to dir: URL) throws {
        guard !entries.isEmpty else { return }
        let iso = ISO8601DateFormatter()
        var out = Data()
        for e in entries {
            let obj: [String: Any] = ["v": 1, "conv": conv, "role": e.role, "text": e.text, "ts": iso.string(from: e.ts), "model": model]
            out += try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])
            out.append(0x0A)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // the id becomes a filename: keep it to safe characters so it can never point outside the journal folder
        let fd = open(dir.appendingPathComponent(safeName(conv) + ".jsonl").path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(fd) }
        var written = 0
        try out.withUnsafeBytes { buf in
            while written < buf.count {
                let n = write(fd, buf.baseAddress! + written, buf.count - written)
                if n < 0 { throw CocoaError(.fileWriteUnknown) }
                written += n
            }
        }
    }
}
