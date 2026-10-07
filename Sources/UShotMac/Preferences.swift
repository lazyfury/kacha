// User preferences: the capture/picker hotkeys and launch-at-login, persisted in
// UserDefaults.

import AppKit
import Carbon.HIToolbox

/// A global hotkey: a virtual key code, its modifiers and a display label.
struct Hotkey: Equatable {
    var keyCode: UInt32
    var modifiers: NSEvent.ModifierFlags
    var keyLabel: String

    /// ⌘⇧A, the default capture shortcut.
    static let `default` = Hotkey(keyCode: 0, modifiers: [.command, .shift], keyLabel: "A")
    /// ⌘⇧C, the default colour-picker shortcut.
    static let pickerDefault = Hotkey(keyCode: 8, modifiers: [.command, .shift], keyLabel: "C")

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

    /// The unified capture shortcut.
    static var captureHotkey: Hotkey {
        get { hotkey("capture", fallback: .default) }
        set { setHotkey("capture", newValue) }
    }

    /// The colour-picker shortcut.
    static var pickerHotkey: Hotkey {
        get { hotkey("picker", fallback: .pickerDefault) }
        set { setHotkey("picker", newValue) }
    }

    private static func hotkey(_ name: String, fallback: Hotkey) -> Hotkey {
        guard
            let code = defaults.object(forKey: "\(name)KeyCode") as? Int,
            let modifiers = defaults.object(forKey: "\(name)Modifiers") as? Int,
            let label = defaults.string(forKey: "\(name)KeyLabel")
        else {
            return fallback
        }
        return Hotkey(
            keyCode: UInt32(code),
            modifiers: NSEvent.ModifierFlags(rawValue: UInt(modifiers)),
            keyLabel: label
        )
    }

    private static func setHotkey(_ name: String, _ value: Hotkey) {
        defaults.set(Int(value.keyCode), forKey: "\(name)KeyCode")
        defaults.set(Int(value.modifiers.rawValue), forKey: "\(name)Modifiers")
        defaults.set(value.keyLabel, forKey: "\(name)KeyLabel")
    }
}
