import SwiftUI
import Carbon.HIToolbox

@main
struct NotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        MenuBarExtra("NotchApp", systemImage: "capsule.fill") {
            Button("Ask…  ⌥Space") { delegate.assistant.toggle() }
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
    private var hotkey: Hotkey?

    func applicationDidFinishLaunching(_ note: Notification) {
        notch = NotchWindow(assistant: assistant)
        notch?.show()
        hotkey = Hotkey(keyCode: kVK_Space, modifiers: optionKey) { [assistant] in assistant.toggle() }
        assistant.connect()
        // rebuild on display changes (plug/unplug, resolution)
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.notch?.show() } }
    }
}
