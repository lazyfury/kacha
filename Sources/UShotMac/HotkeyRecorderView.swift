// A button that records the next key combination when clicked.
//
// Kept in SwiftUI (rather than an AppKit NSButton) so it shares the settings
// form's button chrome and inherits the macOS 26 look. Key capture still uses a
// local NSEvent monitor while recording.

import AppKit
import Carbon.HIToolbox
import SwiftUI

struct HotkeyRecorder: View {
    @Binding var hotkey: Hotkey
    let onChange: (Hotkey) -> Void

    @StateObject private var recorder = HotkeyRecorderModel()

    var body: some View {
        Button {
            recorder.start { newValue in
                hotkey = newValue
                onChange(newValue)
            }
        } label: {
            Text(recorder.isRecording ? "按下快捷键…" : hotkey.display)
                .font(.body.monospaced())
                .frame(minWidth: 54)
        }
        .onDisappear { recorder.stop() }
        .help("点按后按下新的组合键")
    }
}

/// Owns the local event monitor and turns the next key press into a `Hotkey`.
private final class HotkeyRecorderModel: ObservableObject {
    @Published private(set) var isRecording = false

    private var monitor: Any?
    private var commit: ((Hotkey) -> Void)?

    func start(_ commit: @escaping (Hotkey) -> Void) {
        guard monitor == nil else { return }
        self.commit = commit
        isRecording = true
        // While recording, swallow every key event so it never reaches the app.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.handle(event)
            return nil
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        commit = nil
        isRecording = false
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            stop()
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
        let hotkey = Hotkey(keyCode: UInt32(event.keyCode), modifiers: modifiers, keyLabel: label)
        let commit = self.commit
        stop()
        commit?(hotkey)
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
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
