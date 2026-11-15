import SwiftUI
import Sparkle

/// Keeps Dex Notch up to date. Sparkle looks for a newer release about once a day, downloads it in the background, checks it against the
/// signing key built into this app, and then waits: nothing restarts until you say so. (Debug builds stay out of it unless NOTCH_UPDATES is set.)
@MainActor @Observable
final class AppUpdater: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    static let shared = AppUpdater()

    private(set) var readyVersion: String?       // downloaded and verified, waiting for you to restart
    private(set) var status = "Checks once a day."
    private(set) var running = false             // false in a build that has no update feed or key
    var autoUpdate = true { didSet { guard running, autoUpdate != oldValue else { return }; apply() } }

    private var install: (() -> Void)?
    private var controller: SPUStandardUpdaterController!
    private var inspect: Bool { ProcessInfo.processInfo.environment["NOTCH_UPDATES"] != nil }

    var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "" }
    var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "" }

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
    }

    func start() {
        let info = Bundle.main.infoDictionary ?? [:]
        let hasFeed = !((info["SUFeedURL"] as? String) ?? "").isEmpty, hasKey = !((info["SUPublicEDKey"] as? String) ?? "").isEmpty
        #if DEBUG
        guard inspect else { status = "Updates are off in a debug build."; return }
        #endif
        guard hasFeed, hasKey else { status = "This build has no update feed."; return }
        controller.startUpdater()
        running = true
        autoUpdate = controller.updater.automaticallyChecksForUpdates && controller.updater.automaticallyDownloadsUpdates
        if ProcessInfo.processInfo.environment["NOTCH_UPDATE_CHECK_ON_LAUNCH"] != nil { controller.updater.checkForUpdatesInBackground() }
    }

    private func apply() {
        controller.updater.automaticallyChecksForUpdates = autoUpdate
        controller.updater.automaticallyDownloadsUpdates = autoUpdate
    }

    /// Menu and Settings: a check you asked for, with Sparkle's own window.
    func checkNow() {
        guard running else { return }
        NSApp.activate(ignoringOtherApps: true)
        status = "Checking…"
        controller.checkForUpdates(nil)
    }

    /// The one moment that restarts the app: you pressed Restart.
    func restartNow() { install?() }

    // MARK: Sparkle callbacks (Sparkle calls these on the main thread)

    /// Downloaded and verified. Returning true says "I'll decide when": the update is also installed if you simply quit.
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        let v = item.displayVersionString
        nonisolated(unsafe) let handler = immediateInstallHandler       // Sparkle hands this over on the main thread and expects it back there
        NSLog("Dex Notch: update %@ downloaded and verified, waiting for a restart", v)
        MainActor.assumeIsolated { readyVersion = v; install = handler; status = "Version \(v) is ready to install." }
        return true
    }
    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        MainActor.assumeIsolated { if readyVersion == nil { status = "You're up to date." } }
    }
    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let v = item.displayVersionString
        MainActor.assumeIsolated { if readyVersion == nil { status = "Version \(v) found. Downloading…" } }
    }
    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let m = (error as NSError).localizedDescription
        MainActor.assumeIsolated { if readyVersion == nil { status = "Couldn't check for updates: \(m)" } }
    }

    /// A scheduled check must never throw a window at you while you work; only a check you asked for shows one.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool { false }
}
