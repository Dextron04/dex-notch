import Carbon.HIToolbox

/// Global hotkey via Carbon. No Accessibility permission needed.
final class Hotkey {
    nonisolated(unsafe) static var action: (@MainActor () -> Void)?
    private var ref: EventHotKeyRef?

    init(keyCode: Int, modifiers: Int, action: @escaping @MainActor () -> Void) {
        Self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            MainActor.assumeIsolated { Hotkey.action?() }
            return noErr
        }, 1, &spec, nil, nil)
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), EventHotKeyID(signature: 0x4E544348, id: 1),
                            GetApplicationEventTarget(), 0, &ref)
    }
}
