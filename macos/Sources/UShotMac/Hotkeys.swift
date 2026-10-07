// One process-wide hotkey via the Carbon Event Manager.
//
// `RegisterEventHotKey` works without Accessibility permission (unlike a global
// `NSEvent` monitor) and fires even when ushot is not frontmost. The binding is
// re-registered when the user changes it in Settings.

import AppKit
import Carbon.HIToolbox

final class Hotkeys {
    private var handlerRef: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
        installHandler()
    }

    /// Register `hotkey`, replacing any previous binding.
    func register(_ hotkey: Hotkey) {
        unregister()
        let id = EventHotKeyID(signature: OSType(0x7573_6874), id: 1)
        RegisterEventHotKey(
            hotkey.keyCode,
            hotkey.carbonModifiers,
            id,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    private func installHandler() {
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
    }

    deinit {
        unregister()
        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
    }
}
