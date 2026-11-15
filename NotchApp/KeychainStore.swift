import Foundation

/// The local model's bearer token, in the login keychain (never in settings.json).
/// Everything goes through Apple's `security` tool, deliberately. macOS ties an app's "Always Allow" to its exact code signature,
/// which changes with every build, so reading the keychain from the app itself re-asks for your password after each update.
/// `security` has a stable signature, so items it creates or reads never prompt again.
enum KeychainStore {
    private static let tool = URL(fileURLWithPath: "/usr/bin/security")

    private static func quoted(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
    private static func plainASCII(_ s: String) -> Bool { !s.isEmpty && s.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value <= 0x7E } }

    /// One line for `security -i` (read from stdin, so the token never appears in a process listing). nil if anything could break
    /// out of the quotes or can't be read back: newlines, control characters, non-ASCII (security prints those as hex), empty values.
    static func addCommand(service: String, account: String, token: String) -> String? {
        guard plainASCII(service), plainASCII(account), plainASCII(token) else { return nil }
        return "add-generic-password -U -s \(quoted(service)) -a \(quoted(account)) -w \(quoted(token))"
    }

    @discardableResult
    static func set(token: String, service: String, account: String) -> Bool {
        guard let cmd = addCommand(service: service, account: account, token: token) else { return false }
        let p = Process(), inp = Pipe()
        p.executableURL = tool; p.arguments = ["-i"]
        p.standardInput = inp; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        inp.fileHandleForWriting.write(Data((cmd + "\n").utf8)); try? inp.fileHandleForWriting.close()
        p.waitUntilExit()
        return p.terminationStatus == 0 && get(service: service, account: account) == token
    }

    static func get(service: String, account: String) -> String? {
        let p = Process(), out = Pipe()
        p.executableURL = tool; p.arguments = ["find-generic-password", "-s", service, "-a", account, "-w"]
        p.standardOutput = out; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        let t = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return p.terminationStatus == 0 && !t.isEmpty ? t : nil
    }
}
