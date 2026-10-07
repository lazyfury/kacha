// Process-wide hotkeys via the Carbon Event Manager.
//
// `RegisterEventHotKey` works without Accessibility permission (unlike a global
// `NSEvent` monitor) and fires even when kacha is not frontmost. Bindings are
// re-registered when the user changes them in Settings.

import AppKit
import Carbon.HIToolbox

final class Hotkeys {
    /// One binding: a stable id, its key combination and what it runs.
    struct Binding {
        let id: UInt32
        /// Human label, used when registration fails.
        let name: String
        let hotkey: Hotkey
        let action: () -> Void
    }

    private var handlerRef: EventHandlerRef?
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: () -> Void] = [:]

    init() {
        installHandler()
    }

    /// Replace every binding. Returns the names whose registration failed (the
    /// combination is taken by another app), so the caller can tell the user.
    @discardableResult
    func set(_ bindings: [Binding]) -> [String] {
        unregisterAll()
        actions.removeAll()
        var failed: [String] = []
        for binding in bindings {
            actions[binding.id] = binding.action
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: binding.id)
            let status = RegisterEventHotKey(
                binding.hotkey.keyCode,
                binding.hotkey.carbonModifiers,
                id,
                GetApplicationEventTarget(),
                0,
                &ref
            )
            if status == noErr, let ref {
                refs[binding.id] = ref
            } else {
                failed.append(binding.name)
            }
        }
        return failed
    }

    fileprivate func dispatch(_ id: UInt32) {
        actions[id]?()
    }

    private func unregisterAll() {
        for ref in refs.values {
            UnregisterEventHotKey(ref)
        }
        refs.removeAll()
    }

    private func installHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let userData, let event else { return noErr }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                if status == noErr {
                    Unmanaged<Hotkeys>.fromOpaque(userData)
                        .takeUnretainedValue()
                        .dispatch(hotKeyID.id)
                }
                return noErr
            },
            1,
            &eventType,
            context,
            &handlerRef
        )
    }

    deinit {
        unregisterAll()
        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
    }

    /// The four-character code 'kach', namespacing this app's hotkey ids.
    private static let signature = OSType(0x6B61_6368)
}
