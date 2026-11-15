import SwiftUI
import Carbon.HIToolbox

@main
struct NotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    private var updater: AppUpdater { AppUpdater.shared }
    private var center: AddonCenter { AddonCenter.shared }

    var body: some Scene {
        MenuBarExtra {
            Button("Ask…  ⌥Space") { delegate.assistant.toggle() }
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

    func applicationDidFinishLaunching(_ note: Notification) {
        notch = NotchWindow(assistant: assistant)
        notch?.show()
        hotkeys = [
            Hotkey(id: 1, keyCode: kVK_Space, modifiers: optionKey) { [assistant] in assistant.toggle() },
            Hotkey(id: 2, keyCode: kVK_Space, modifiers: optionKey | shiftKey) { [assistant] in assistant.toggleRecall() },
        ]
        assistant.connect()
        AddonCenter.shared.start(assistant: assistant)
        AppUpdater.shared.start()
        if SetupWindow.needsWalkthrough {      // first launch: walk through every permission and choice, don't make people hunt for a config file
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [assistant] in SetupWindow.shared.show(assistant: assistant, guided: true) }
        }
        // rebuild on display changes (plug/unplug, resolution)
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.notch?.show() } }
    }

    func applicationWillTerminate(_ note: Notification) { assistant.persist() } // ⌘Q / logout mid-thought still keeps the conversation
}
