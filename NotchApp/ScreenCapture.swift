import AppKit
import ScreenCaptureKit

/// One screenshot of the display the notch lives on, written into the scratch folder where the CLIs can see it.
struct Shot {
    var url: URL
    var pixelSize: CGSize
    var screenFrame: CGRect      // the NSScreen frame in global points: where marks map back to
    var thumb: NSImage
}

/// Only ever called because the user turned the eye on (hotkey, chip) or asked about their screen in so many words.
@MainActor
enum ScreenCapture {
    struct Denied: Error { let msg: String }
    static let maxEdge: CGFloat = 1568      // what vision models see anyway
    private static var asked = false

    static let eyeName = "screen.png", lookName = "screen-look.png"

    /// Written atomically (the old file stays valid until the new one is whole), readable by this user only.
    static func capture(name: String = eyeName) async throws -> Shot {
        guard CGPreflightScreenCaptureAccess() else {
            if !asked { asked = true; _ = CGRequestScreenCaptureAccess() }
            throw Denied(msg: "Screen Recording is off. Allow Dex Notch in System Settings → Privacy & Security.")
        }
        guard let screen = NotchWindow.targetScreen(), let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { throw Denied(msg: "No display to capture.") }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == id }) else { throw Denied(msg: "No display to capture.") }
        let me = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }      // the notch itself is not in the shot
        let k = min(1, maxEdge / max(screen.frame.width, screen.frame.height))
        let cfg = SCStreamConfiguration()
        cfg.width = Int(screen.frame.width * k); cfg.height = Int(screen.frame.height * k); cfg.showsCursor = false
        let img = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingApplications: me, exceptingWindows: []), configuration: cfg)
        let rep = NSBitmapImageRep(cgImage: img)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw Denied(msg: "Couldn't save the screenshot.") }
        let url = AgentRunner.scratch.appendingPathComponent(name)
        try png.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return Shot(url: url, pixelSize: CGSize(width: img.width, height: img.height), screenFrame: screen.frame, thumb: NSImage(cgImage: img, size: NSSize(width: 44, height: 28)))
    }

    /// Screenshots never outlive the app: gone at launch (a crash may have left one) and at quit.
    static func sweep() {
        let fm = FileManager.default
        for n in (try? fm.contentsOfDirectory(atPath: AgentRunner.scratch.path)) ?? [] where n.hasPrefix("screen") && n.hasSuffix(".png") { try? fm.removeItem(at: AgentRunner.scratch.appendingPathComponent(n)) }
    }
    static func remove(_ s: Shot?) { if let s { try? FileManager.default.removeItem(at: s.url) } }
}
