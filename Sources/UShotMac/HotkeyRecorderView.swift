// A button that records the next key combination when clicked.

import AppKit
import Carbon.HIToolbox

final class HotkeyRecorderView: NSButton {
    var hotkey: Hotkey {
        didSet { title = hotkey.display }
    }
    var onChange: ((Hotkey) -> Void)?

    private var monitor: Any?

    init(hotkey: Hotkey) {
        self.hotkey = hotkey
        super.init(frame: NSRect(x: 0, y: 0, width: 140, height: 24))
        bezelStyle = .rounded
        target = self
        action = #selector(startRecording)
        title = hotkey.display
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("HotkeyRecorderView is created programmatically") }

    deinit {
        stopRecording()
    }

    @objc private func startRecording() {
        guard monitor == nil else { return }
        title = "按下快捷键…"
        // A local monitor captures the combination; the settings window is key.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.handle(event)
            return nil
        }
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            stopRecording()
            return
        }
        let modifiers = event.modifierFlags.intersection(Hotkey.relevantModifiers)
        // A shortcut needs a real modifier (command/option/control); shift alone
        // would swallow ordinary typing.
        guard modifiers.contains(.command) || modifiers.contains(.option) || modifiers.contains(.control)
        else {
            NSSound.beep()
            return
        }
        let characters = event.charactersIgnoringModifiers ?? ""
        let label = characters.isEmpty ? Self.label(for: event.keyCode) : characters
        hotkey = Hotkey(keyCode: UInt32(event.keyCode), modifiers: modifiers, keyLabel: label)
        stopRecording()
        onChange?(hotkey)
    }

    private func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        title = hotkey.display
    }

    /// A readable label for keys that do not produce a character.
    private static func label(for keyCode: UInt16) -> String {
        switch Int(keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Home: return "↖"
        case kVK_End: return "↘"
        case kVK_PageUp: return "⇞"
        case kVK_PageDown: return "⇟"
        default: return "Key\(keyCode)"
        }
    }
}
