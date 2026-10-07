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
    /// ⌘⇧F, the default full-screen-capture shortcut.
    static let fullScreenDefault = Hotkey(keyCode: 3, modifiers: [.command, .shift], keyLabel: "F")
    /// ⌘⇧R, the default screen-recording shortcut.
    static let recordDefault = Hotkey(keyCode: 15, modifiers: [.command, .shift], keyLabel: "R")

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

    /// The key equivalent a menu item can show, or nil when the label is not a
    /// single letter/digit (those cannot be menu key equivalents).
    var menuKeyEquivalent: (key: String, modifiers: NSEvent.ModifierFlags)? {
        guard
            keyLabel.count == 1,
            let character = keyLabel.first,
            character.isLetter || character.isNumber
        else {
            return nil
        }
        return (String(character).lowercased(), modifiers)
    }

    /// Apply this hotkey as a menu item's key equivalent (clearing it otherwise).
    func apply(to item: NSMenuItem?) {
        if let equivalent = menuKeyEquivalent {
            item?.keyEquivalent = equivalent.key
            item?.keyEquivalentModifierMask = equivalent.modifiers
        } else {
            item?.keyEquivalent = ""
            item?.keyEquivalentModifierMask = []
        }
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

    /// The full-screen-capture shortcut.
    static var fullScreenHotkey: Hotkey {
        get { hotkey("fullscreen", fallback: .fullScreenDefault) }
        set { setHotkey("fullscreen", newValue) }
    }

    /// The screen-recording shortcut.
    static var recordHotkey: Hotkey {
        get { hotkey("record", fallback: .recordDefault) }
        set { setHotkey("record", newValue) }
    }

    /// Play the system shutter sound when a capture is committed. Defaults to on
    /// (an unset key must not read as `false`).
    static var playSound: Bool {
        get { defaults.object(forKey: "playSound") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "playSound") }
    }

    /// Seconds to wait before a delayed capture (0 = capture immediately). The
    /// only offered values are `delayChoices`.
    static var delaySeconds: Int {
        get { defaults.object(forKey: "delaySeconds") as? Int ?? 0 }
        set { defaults.set(newValue, forKey: "delaySeconds") }
    }

    /// The delayed-capture presets, in seconds (0 first, ascending).
    static let delayChoices = [0, 3, 5, 10]

    /// The countdown-before-recording presets, in seconds.
    static let countdownChoices = [0, 3, 5]

    /// The recording options, persisted as raw values.
    static var recordingConfig: RecordingConfig {
        get {
            // Default to system + microphone when the app can use the mic;
            // otherwise there is nothing to capture.
            let defaultAudio: RecordingAudio =
                MicrophonePermission.status == .unavailable ? .none : .systemAndMicrophone
            return RecordingConfig(
                frameRate: RecordingFrameRate(
                    rawValue: defaults.object(forKey: "recordFPS") as? Int ?? 30
                ) ?? .fps30,
                codec: RecordingCodec(rawValue: defaults.string(forKey: "recordCodec") ?? "")
                    ?? .h264,
                container: RecordingContainer(
                    rawValue: defaults.string(forKey: "recordContainer") ?? ""
                ) ?? .mp4,
                audio: RecordingAudio(rawValue: defaults.string(forKey: "recordAudio") ?? "")
                    ?? defaultAudio,
                showCursor: defaults.object(forKey: "recordShowCursor") as? Bool ?? true,
                showClicks: defaults.object(forKey: "recordShowClicks") as? Bool ?? false,
                countdown: defaults.object(forKey: "recordCountdown") as? Int ?? 0
            )
        }
        set {
            defaults.set(newValue.frameRate.rawValue, forKey: "recordFPS")
            defaults.set(newValue.codec.rawValue, forKey: "recordCodec")
            defaults.set(newValue.container.rawValue, forKey: "recordContainer")
            defaults.set(newValue.audio.rawValue, forKey: "recordAudio")
            defaults.set(newValue.showCursor, forKey: "recordShowCursor")
            defaults.set(newValue.showClicks, forKey: "recordShowClicks")
            defaults.set(newValue.countdown, forKey: "recordCountdown")
        }
    }

    /// The folder a capture is saved into without a panel, or nil to always ask.
    /// Stored as a bookmark (not a raw path) so it survives the folder being
    /// renamed or moved.
    static var saveDirectory: URL? {
        get {
            guard let data = defaults.data(forKey: "saveDirectoryBookmark") else { return nil }
            var stale = false
            return try? URL(
                resolvingBookmarkData: data,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
        }
        set {
            guard let newValue else {
                defaults.removeObject(forKey: "saveDirectoryBookmark")
                return
            }
            let data = try? newValue.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            defaults.set(data, forKey: "saveDirectoryBookmark")
        }
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
