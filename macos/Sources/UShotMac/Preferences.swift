// User preferences: the capture hotkey and launch-at-login, persisted in
// UserDefaults.

import AppKit
import Carbon.HIToolbox

/// A global hotkey: a virtual key code, its modifiers and a display label.
struct Hotkey: Equatable {
    var keyCode: UInt32
    var modifiers: NSEvent.ModifierFlags
    var keyLabel: String

    /// ⌘⇧A, the default.
    static let `default` = Hotkey(keyCode: 0, modifiers: [.command, .shift], keyLabel: "A")

    /// The shortcut modifiers only (not caps lock / fn / numeric pad).
    static let relevantModifiers: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

    var display: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + keyLabel.uppercased()
    }

    /// The Carbon modifier mask for `RegisterEventHotKey`.
    var carbonModifiers: UInt32 {
        var mask: UInt32 = 0
        if modifiers.contains(.command) { mask |= UInt32(cmdKey) }
        if modifiers.contains(.shift) { mask |= UInt32(shiftKey) }
        if modifiers.contains(.option) { mask |= UInt32(optionKey) }
        if modifiers.contains(.control) { mask |= UInt32(controlKey) }
        return mask
    }
}

enum Preferences {
    private static let defaults = UserDefaults.standard

    private enum Key {
        static let code = "captureKeyCode"
        static let modifiers = "captureModifiers"
        static let label = "captureKeyLabel"
    }

    static var captureHotkey: Hotkey {
        get {
            guard
                let code = defaults.object(forKey: Key.code) as? Int,
                let modifiers = defaults.object(forKey: Key.modifiers) as? Int,
                let label = defaults.string(forKey: Key.label)
            else {
                return .default
            }
            return Hotkey(
                keyCode: UInt32(code),
                modifiers: NSEvent.ModifierFlags(rawValue: UInt(modifiers)),
                keyLabel: label
            )
        }
        set {
            defaults.set(Int(newValue.keyCode), forKey: Key.code)
            defaults.set(Int(newValue.modifiers.rawValue), forKey: Key.modifiers)
            defaults.set(newValue.keyLabel, forKey: Key.label)
        }
    }
}
