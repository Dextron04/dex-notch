import SwiftUI
import Carbon.HIToolbox

/// The entry point. The CLIs start this binary as their screen tool (`--screen-mcp`): that branch runs before SwiftUI, the delegate or any hotkey exists.
@main
enum Launcher {
    static func main() {
        if CommandLine.arguments.contains(ScreenTool.flag) { ScreenMCP.serve(); exit(0) }
        NotchApp.main()
    }
}

struct NotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    private var updater: AppUpdater { AppUpdater.shared }
    private var center: AddonCenter { AddonCenter.shared }
    private var gate: AccountGate { AccountGate.shared }

    var body: some Scene {
        MenuBarExtra {
            if !gate.isOpen {                // nothing runs until the server has confirmed the account
                Button("Sign in to Dex Notch…") { GateWindow.shared.show() }
                if let v = updater.readyVersion { Button("Restart to update to \(v)") { updater.restartNow() } }
            } else {
            Button("Ask…  ⌥Space") { delegate.assistant.toggle() }
            Button("Ask by voice  hold ⌥Space") {}.disabled(true)
            Button("Ask about my screen…  ⌥⌘S") { delegate.assistant.screenHotkey() }
            Button("Recall…  ⌥⇧Space") { delegate.assistant.toggleRecall() }
            if !center.needsReconnect.isEmpty { Button("Reconnect Gmail (\(center.needsReconnect.count))…") { center.reconnectAll() } }
            if let v = updater.readyVersion { Button("Restart to update to \(v)") { updater.restartNow() } }
            if let who = center.resumable { Button("Resume reply to \(who)") { center.resumeReply() } }
            if center.waiting > 0 { Button("Show \(center.waiting) waiting alert\(center.waiting == 1 ? "" : "s")") { center.showWaiting() } }
            Button("Check for Updates…") { updater.checkNow() }.disabled(!updater.running)
            Divider()
            Button("Check mail now") { AddonCenter.shared.checkNow() }
            Button("Settings…") { SetupWindow.shared.show(assistant: delegate.assistant) }.keyboardShortcut(",")
            Button("Open settings.json") { delegate.assistant.openSettings() }
            Button("Check connection") { delegate.assistant.connect() }
            }
            Divider()
            Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
        } label: {
            HStack(spacing: 3) {
                Image("MenuBarMark")
                if updater.readyVersion != nil || !center.needsReconnect.isEmpty { Image(systemName: "circle.fill").font(.system(size: 5)) }       // an update is waiting for you to restart
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let assistant = Assistant()
    private var notch: NotchWindow?
    private var hotkeys: [Hotkey] = []
    private var walkthrough = false

    func applicationDidFinishLaunching(_ note: Notification) {
        walkthrough = SetupWindow.needsWalkthrough      // asked now: signing in writes settings.json, which would make a fresh install look like an old one
        AppUpdater.shared.start()          // even before sign-in: an update may be what fixes a problem
        AccountGate.shared.onOpen = { [weak self] in self?.startApp() }
        AccountGate.shared.launch()        // starts the app, once the server confirms this Mac's account
    }

    // ⌥Space: a quick tap toggles the notch (on release); holding past the threshold opens it and listens, release sends.
    private var space = TapOrHold()
    private var spaceTimer: Task<Void, Never>?
    private var spaceAsking = false

    private func spacePressed() {
        guard space.press() else { return }
        spaceTimer?.cancel()
        guard DictationLogic.enabled(at: Settings.defaultURL) else { return }      // voice off: a hold is just a slow tap (no timer, no mic)
        spaceTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(TapOrHold.threshold))
            guard !Task.isCancelled, let self, self.space.thresholdPassed() else { return }
            self.spaceAsking = Dictation.shared.start()
            if self.spaceAsking { self.assistant.open(.prompt) }
        }
    }

    private func spaceReleased() {
        spaceTimer?.cancel()
        switch space.release() {
        case .tap: assistant.toggle()
        case .endHold: if spaceAsking { Dictation.shared.stop() }; spaceAsking = false
        case .ignored: break
        }
    }

    private func startApp() {
        ScreenCapture.sweep()      // a screenshot left by a crash
        notch = NotchWindow(assistant: assistant)
        notch?.show()
        hotkeys = [
            Hotkey(id: 1, keyCode: kVK_Space, modifiers: optionKey, action: { [weak self] in self?.spacePressed() }, onRelease: { [weak self] in self?.spaceReleased() }),   // tap toggles, hold asks by voice
            Hotkey(id: 2, keyCode: kVK_Space, modifiers: optionKey | shiftKey) { [assistant] in assistant.toggleRecall() },
            Hotkey(id: 3, keyCode: kVK_ANSI_S, modifiers: optionKey | cmdKey) { [assistant] in assistant.screenHotkey() },
        ]
        Dictation.shared.assistant = assistant
        Task { await VoiceLanguages.shared.refresh() }      // which models are installed; nothing downloads until you ask
        assistant.connect()
        assistant.startScreenBridge()
        AddonCenter.shared.start(assistant: assistant)
        ConnectionMonitor.shared.onMissing = { s, c in AddonCenter.shared.queueConnectCard(s, c) }
        ConnectionMonitor.shared.openSettings = { [assistant] in SetupWindow.shared.show(assistant: assistant, pane: .memory) }
        ConnectionMonitor.shared.start()
        RecorderInstaller.shared.refresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {       // once, after sign-up, if they chose to keep their conversations: the welcome window says so
            let r = RecorderInstaller.shared
            if r.status == .notInstalled, HostedAccount.uploads(at: Settings.defaultURL), !UserDefaults.standard.bool(forKey: "recorderAutoStarted") {
                UserDefaults.standard.set(true, forKey: "recorderAutoStarted"); r.install()
            } else { r.updateIfNeeded() }
        }
        if walkthrough {      // first launch: walk through every permission and choice, don't make people hunt for a config file
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [assistant] in SetupWindow.shared.show(assistant: assistant, guided: true) }
        }
        // NOTCH_OPEN_SETTINGS=models|folders|mail|iphone|updates opens Settings on that page (README screenshots)
        if let p = ProcessInfo.processInfo.environment["NOTCH_OPEN_SETTINGS"], !p.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [assistant] in SetupWindow.shared.show(assistant: assistant) }
        }
        #if DEBUG
        // NOTCH_DEMO_DRAFT=<text> opens the notch with that text in the field (\n is a newline): layout checks
        if let d = ProcessInfo.processInfo.environment["NOTCH_DEMO_DRAFT"], !d.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [assistant] in assistant.open(.prompt); assistant.draft = d.replacingOccurrences(of: "\\n", with: "\n") }
        }
        #endif
        // rebuild on display changes (plug/unplug, resolution)
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.notch?.show() } }
    }

    func applicationWillTerminate(_ note: Notification) { assistant.persist(); ScreenCapture.sweep() } // ⌘Q / logout mid-thought still keeps the conversation
}
