import Carbon.HIToolbox

/// Global hotkeys via Carbon. No Accessibility permission needed. Several can coexist, keyed by `id`.
final class Hotkey {
    nonisolated(unsafe) private static var actions: [UInt32: @MainActor () -> Void] = [:]
    nonisolated(unsafe) private static var installed = false
    private var ref: EventHotKeyRef?
    private let id: UInt32

    init(id: UInt32 = 1, keyCode: Int, modifiers: Int, action: @escaping @MainActor () -> Void) {
        self.id = id
        Self.actions[id] = action
        if !Self.installed {
            Self.installed = true
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var hk = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
                NSLog("NotchApp: hotkey %u pressed", hk.id)
                MainActor.assumeIsolated { Hotkey.actions[hk.id]?() }
                return noErr
            }, 1, &spec, nil, nil)
        }
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), EventHotKeyID(signature: 0x4E544348, id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        NSLog("NotchApp: hotkey id %u registered (status %d)", id, status)
        if status != noErr { NSLog("NotchApp: hotkey id %u failed to register (OSStatus %d) — another app may own that combination", id, status) }
    }

    /// Hotkeys that only exist for a while (the alert card's keys) give the combination back when released.
    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        let id = self.id
        DispatchQueue.main.async { Hotkey.actions[id] = nil }
    }
}
