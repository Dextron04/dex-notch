import Foundation
import Darwin

/// App side of `look_at_screen`: a unix socket only this user can reach. The MCP helper (the app binary run with `--screen-mcp`) connects,
/// sends {"token","reason"} and gets {"path","w","h"} or {"error"}. The capture itself happens in the app (its permission, its windows excluded).
final class ScreenBridge: @unchecked Sendable {
    static let shared = ScreenBridge()
    static var socketPath: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NotchApp/screen.sock").path
    }
    private var handler: (@Sendable (Data) async -> Data)?
    private var started = false

    func start(_ h: @escaping @Sendable (Data) async -> Data) {
        handler = h
        guard !started else { return }
        let path = Self.socketPath
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        guard fd >= 0, path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else { return }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: path.utf8) }
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } } == 0
        guard ok else { close(fd); return }
        chmod(path, 0o600); listen(fd, 4); started = true
        Thread.detachNewThread { [self] in
            while true {
                let c = accept(fd, nil, nil)
                if c < 0 { continue }
                Thread.detachNewThread { [self] in serve(c) }
            }
        }
    }

    private func serve(_ c: Int32) {
        defer { close(c) }
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(c, &uid, &gid) == 0, uid == getuid() else { return }
        var req = Data(), buf = [UInt8](repeating: 0, count: 4096)
        while !req.contains(10), req.count < 8192 { let n = read(c, &buf, buf.count); if n <= 0 { break }; req.append(contentsOf: buf[0..<n]) }
        let box = Box(), sem = DispatchSemaphore(value: 0), h = handler
        Task { box.out = await h?(req) ?? Data(); sem.signal() }
        sem.wait()
        let out = box.out + Data([10])
        _ = out.withUnsafeBytes { write(c, $0.baseAddress, out.count) }
    }
    private final class Box: @unchecked Sendable { var out = Data() }
}

/// `Dex Notch --screen-mcp`: the stdio MCP server the CLIs start. It never captures: it asks the running app.
enum ScreenMCP {
    static func serve() {
        let env = ProcessInfo.processInfo.environment
        while let line = readLine() {
            guard let r = ScreenTool.reply(to: line, look: { ask(env, reason: $0) }) else { continue }
            print(r); fflush(stdout)
        }
    }

    private static func ask(_ env: [String: String], reason: String?) -> Result<ScreenTool.Look, ScreenTool.LookError> {
        func fail(_ m: String) -> Result<ScreenTool.Look, ScreenTool.LookError> { .failure(.init(message: m)) }
        guard let path = env[ScreenTool.sockEnv], let token = env[ScreenTool.tokenEnv] else { return fail("Screen access isn't configured.") }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        guard fd >= 0, path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else { return fail("Screen access isn't available.") }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: path.utf8) }
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } } == 0
        guard ok else { return fail("Dex Notch isn't running, so there's no screen to look at.") }
        var msg = (try? JSONSerialization.data(withJSONObject: ["token": token, "reason": reason ?? ""])) ?? Data()
        msg.append(10)
        _ = msg.withUnsafeBytes { write(fd, $0.baseAddress, msg.count) }
        var resp = Data(), buf = [UInt8](repeating: 0, count: 4096)
        while true { let n = read(fd, &buf, buf.count); if n <= 0 { break }; resp.append(contentsOf: buf[0..<n]) }
        guard let j = try? JSONSerialization.jsonObject(with: resp) as? [String: Any] else { return fail("No answer from Dex Notch.") }
        if let e = j["error"] as? String { return fail(e) }
        guard let p = j["path"] as? String, let w = j["w"] as? Int, let h = j["h"] as? Int, let png = FileManager.default.contents(atPath: p) else { return fail("Couldn't read the screenshot.") }
        return .success(.init(png: png, width: w, height: h))
    }
}
