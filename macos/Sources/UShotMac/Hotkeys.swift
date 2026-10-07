// Process-wide hotkeys via the Carbon Event Manager.
//
// `RegisterEventHotKey` works without Accessibility permission (unlike a global
// `NSEvent` monitor) and fires even when ushot is not frontmost — which is the
// point of a screenshot tool.

import Carbon.HIToolbox

final class Hotkeys {
    /// ⌘⇧A — capture a region.
    static let keyA: UInt32 = UInt32(kVK_ANSI_A)
    /// ⌘⇧W — capture a window.
    static let keyW: UInt32 = UInt32(kVK_ANSI_W)

    private var handlerRef: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?
    private let action: () -> Void
    private let keyCode: UInt32
    private let id: UInt32

    init(keyCode: UInt32, id: UInt32, action: @escaping () -> Void) {
        self.keyCode = keyCode
        self.id = id
        self.action = action
    }

    /// Register this hotkey (⌘⇧ + `keyCode`).
    func register() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData -> OSStatus in
                guard let userData else { return noErr }
                let hotkeys = Unmanaged<Hotkeys>.fromOpaque(userData).takeUnretainedValue()
                hotkeys.action()
                return noErr
            },
            1,
            &eventType,
            context,
            &handlerRef
        )

        // 'usht' signature; the id distinguishes the two hotkeys.
        let hotKeyID = EventHotKeyID(signature: OSType(0x7573_6874), id: id)
        RegisterEventHotKey(
            keyCode,
            UInt32(cmdKey | shiftKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    deinit {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
    }
}
