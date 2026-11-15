import SwiftUI

/// Borderless panel that can take keyboard focus without stealing the active app's menu bar.
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Fixed-size panel pinned top-center of the notched screen, above the menu bar.
/// It never resizes (content-driven resizing shifts it off-center); the SwiftUI pill animates inside it.
@MainActor
final class NotchWindow {
    static let panelWidth: CGFloat = 640
    static let maxBody: CGFloat = 280 // tallest the answer area grows before it scrolls

    private let assistant: Assistant
    private var panel: KeyPanel?
    private var resignObserver: NSObjectProtocol?
    private var keyMonitor: Any?
    private var hoverTimer: Timer?

    init(assistant: Assistant) { self.assistant = assistant }

    /// The screen the notch lives on: the built-in display with the real notch, or (lid closed, or no notch) the main display with a drawn one.
    /// NOTCH_FAKE_NOTCH=1 picks a display without a notch, to see how that looks.
    static func targetScreen() -> NSScreen? {
        if ProcessInfo.processInfo.environment["NOTCH_FAKE_NOTCH"] != nil, let s = NSScreen.screens.first(where: { $0.safeAreaInsets.top == 0 }) { return s }
        return NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main
    }

    /// Notch rect size on the built-in display. Falls back to a fake notch on non-notch Macs.
    static func notchSize(for screen: NSScreen) -> CGSize {
        let h = screen.safeAreaInsets.top
        guard h > 0, let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea
        else { return CGSize(width: 200, height: 32) } // ponytail: fake notch for external displays
        return CGSize(width: screen.frame.width - l.width - r.width, height: h)
    }

    func show() {
        panel?.close()
        if let o = resignObserver { NotificationCenter.default.removeObserver(o) }
        guard let screen = Self.targetScreen() else { return }

        let notch = Self.notchSize(for: screen)
        let size = CGSize(width: Self.panelWidth, height: notch.height + Self.maxBody + 250)
        let origin = CGPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height)

        let p = KeyPanel(contentRect: NSRect(origin: origin, size: size),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.ignoresMouseEvents = !assistant.isOpen // transparent panel must not eat clicks while collapsed
        let host = NSHostingView(rootView: NotchView(a: assistant, notch: notch, panel: size))
        host.sizingOptions = []
        p.contentView = host
        p.setFrame(NSRect(origin: origin, size: size), display: false)
        p.orderFrontRegardless()
        panel = p

        if let k = keyMonitor { NSEvent.removeMonitor(k) }
        // Recall view has no text field to hold focus, so its keys are handled here (SwiftUI focus is unreliable in a non-activating panel)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [assistant] e in
            let code = e.keyCode, flags = e.modifierFlags // NSEvent isn't Sendable: copy what we need
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard assistant.isOpen else { return false }
                if assistant.mode == .prompt, code == 45, flags.contains(.command), flags.intersection([.option, .control]).isEmpty {
                    assistant.newConversation(); return true     // ⌘N
                }
                if assistant.mode == .prompt {   // model dial: ⇥ / ⇧⇥ cycle, ⌘1 ⌘2 ⌘3 jump, ⌘E toggles edit rights
                    guard !assistant.busy else { return false }
                    let cmd = flags.contains(.command) && flags.intersection([.option, .control]).isEmpty
                    switch code {
                    case 48 where flags.intersection([.command, .option, .control]).isEmpty: assistant.cycleBackend(flags.contains(.shift) ? -1 : 1)
                    case 18 where cmd: assistant.setBackendAt(0)
                    case 19 where cmd: assistant.setBackendAt(1)
                    case 20 where cmd: assistant.setBackendAt(2)
                    case 14 where cmd: assistant.toggleWork()
                    case 3 where cmd: assistant.cycleFolder()     // ⌘F
                    default: return false
                    }
                    return true
                }
                guard assistant.mode == .recall else { return false }
                switch code {
                case 48: assistant.stepPage(flags.contains(.shift) ? -1 : 1)                         // ⇥ / ⇧⇥ switch page
                case 123: if assistant.page == .activity { assistant.moveCursor(-1) } else { assistant.stepPage(-1) }   // ←
                case 124: if assistant.page == .activity { assistant.moveCursor(1) } else { assistant.stepPage(1) }     // →
                case 126: assistant.moveSelection(-1)                                                // ↑
                case 125: assistant.moveSelection(1)                                                 // ↓
                case 36, 76:                                                                         // ↩ / keypad enter
                    if flags.contains(.command) { assistant.summarizeSelected() } else { assistant.openSelectedNote() }
                case 53:                                                                             // esc: leave search first, then close
                    if assistant.searching { assistant.searching = false; assistant.recallQuery = "" } else { assistant.close() }
                case 44 where !assistant.searching && assistant.page == .chats && flags.intersection([.command, .option, .control]).isEmpty:
                    assistant.searching = true                                                       // "/"
                default: return false
                }
                return true
            }
            return handled ? nil : e
        }
        // An alert card needs clicks; the rest of the (transparent) panel must not eat them. Follow the pointer and let events through everywhere else.
        let card = CGRect(x: screen.frame.midX - AlertView.width / 2, y: screen.frame.maxY - AlertView.height(notch), width: AlertView.width, height: AlertView.height(notch)).insetBy(dx: -6, dy: -6)
        AddonCenter.shared.onPresenting = { [weak self, weak p] on in
            self?.hoverTimer?.invalidate(); self?.hoverTimer = nil
            guard let p else { return }
            guard on else { AddonCenter.shared.hovering = false; p.ignoresMouseEvents = !(self?.assistant.isOpen ?? false); return }
            self?.hoverTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in
                MainActor.assumeIsolated {
                    let hot = card.contains(NSEvent.mouseLocation)
                    AddonCenter.shared.hovering = hot
                    p.ignoresMouseEvents = !hot
                }
            }
        }
        // Writing a reply needs the keyboard: take focus for as long as the reply panel is open, then give the screen back.
        AddonCenter.shared.onReply = { [weak self, weak p] on in
            guard let p else { return }
            if on {
                self?.hoverTimer?.invalidate(); self?.hoverTimer = nil
                p.ignoresMouseEvents = false
                NSApp.activate(ignoringOtherApps: true); p.makeKeyAndOrderFront(nil)
            } else { p.ignoresMouseEvents = !(self?.assistant.isOpen ?? false) }
        }
        assistant.onOpenChange = { [weak p] open in
            guard let p else { return }
            p.ignoresMouseEvents = !open
            if open { NSApp.activate(ignoringOtherApps: true); p.makeKeyAndOrderFront(nil) }
        }
        // click anywhere else → panel loses key → collapse
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: p, queue: .main
        ) { [assistant] _ in MainActor.assumeIsolated { assistant.close(); AddonCenter.shared.collapseReply(); AddonCenter.shared.closeNotes() } }
    }
}
