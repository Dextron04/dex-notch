import SwiftUI
import Carbon.HIToolbox

@main
struct NotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        MenuBarExtra("NotchApp", systemImage: "capsule.fill") {
            Button("Ask…  ⌥Space") { delegate.assistant.toggle() }
            Button("Recall…  ⌥⇧Space") { delegate.assistant.toggleRecall() }
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
        // rebuild on display changes (plug/unplug, resolution)
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.notch?.show() } }
    }
}
