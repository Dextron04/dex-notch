import Foundation

/// The recorder is a small Python program (standard library only) that writes your agents' conversations into a vault and uploads them to your account.
/// The app carries a copy and runs it as a per-user background job. Everything here is pure, so it can be tested.
enum RecorderLogic {
    static let label = "in.dextron04.agentvault"

    enum Status: Equatable {
        case running
        case stopped                      // installed by the app but not running
        case notInstalled
        case elsewhere(String)            // someone set up their own copy (a developer's checkout): the app leaves it alone
        case needsPython                  // no python3 to run it with (needs Apple's command line tools)
    }

    /// The launchd job. Paths are escaped because they go into XML.
    static func plist(python: String, memoryDir: String, vault: String) -> String {
        func x(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>Label</key><string>\(label)</string>
          <key>ProgramArguments</key><array>
            <string>\(x(python))</string><string>-m</string><string>agentvault</string><string>run</string>
            <string>--vault</string><string>\(x(vault))</string>
          </array>
          <key>WorkingDirectory</key><string>\(x(memoryDir))</string>
          <key>RunAtLoad</key><true/>
          <key>KeepAlive</key><true/>
          <key>ProcessType</key><string>Background</string>
          <key>Nice</key><integer>10</integer>
          <key>StandardErrorPath</key><string>\(x(vault))/.recorder/recorder.log</string>
          <key>StandardOutPath</key><string>\(x(vault))/.recorder/recorder.log</string>
        </dict></plist>

        """
    }

    /// `plistText`: the installed job file, if there is one. It is ours only if it points into the folder the app keeps.
    static func status(plistText: String?, memoryDir: String, running: Bool, python: Bool) -> Status {
        guard let text = plistText else { return python ? .notInstalled : .needsPython }
        guard text.contains(memoryDir) else {
            let dir = text.components(separatedBy: "<key>WorkingDirectory</key><string>").dropFirst().first?.components(separatedBy: "</string>").first ?? "another folder"
            return .elsewhere(dir)
        }
        return running ? .running : .stopped
    }

    static func text(_ s: Status) -> String {
        switch s {
        case .running: return "Recording your conversations."
        case .stopped: return "Installed, but not running."
        case .notInstalled: return "Not recording yet. Your conversations aren't being saved."
        case .elsewhere(let dir): return "Already running from \(dir)."
        case .needsPython: return "Needs Python. Run xcode-select --install in Terminal, then try again."
        }
    }

    /// Whether the copy the app carries is newer than the one running (the app was updated).
    static func needsUpdate(installed: String?, app: String) -> Bool { installed != app }

    /// Puts a fresh copy of the recorder at `dest` without ever leaving it empty: copy beside it, then swap. If the copy fails, the old one is untouched.
    nonisolated static func swapIn(_ src: URL, to dest: URL) throws {
        let fm = FileManager.default
        let tmp = dest.deletingLastPathComponent().appendingPathComponent(".\(dest.lastPathComponent).new-\(UUID().uuidString)")
        do {
            try fm.copyItem(at: src, to: tmp)
            if fm.fileExists(atPath: dest.path) { _ = try fm.replaceItemAt(dest, withItemAt: tmp) } else { try fm.moveItem(at: tmp, to: dest) }
        } catch { try? fm.removeItem(at: tmp); throw error }
    }
}
