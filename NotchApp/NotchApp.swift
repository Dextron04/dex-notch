import SwiftUI
import Carbon.HIToolbox

@main
struct NotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        MenuBarExtra("NotchApp", systemImage: "capsule.fill") {
            Button("Ask…  ⌥Space") { delegate.assistant.toggle() }
            Button("Recall…  ⌥⇧Space") { delegate.assistant.toggleRecall() }
            Button("Settings…") { SetupWindow.shared.show(assistant: delegate.assistant) }.keyboardShortcut(",")
            Button("Open settings.json") { delegate.assistant.openSettings() }
            Button("Check connection") { delegate.assistant.connect() }
            Divider()
            Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
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
        if !FileManager.default.fileExists(atPath: Settings.defaultURL.path) {      // first launch: ask, don't make people hunt for a config file
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [assistant] in SetupWindow.shared.show(assistant: assistant) }
        }
        // rebuild on display changes (plug/unplug, resolution)
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.notch?.show() } }
    }

    func applicationWillTerminate(_ note: Notification) { assistant.persist() } // ⌘Q / logout mid-thought still keeps the conversation
}
