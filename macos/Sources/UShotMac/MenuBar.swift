// The menu-bar item: ushot's entry point when it is not driven from the menu.

import AppKit

final class MenuBar {
    private let statusItem: NSStatusItem
    private let onCapture: () -> Void
    private let onPicker: () -> Void
    private let onSettings: () -> Void
    private let onQuit: () -> Void
    private var captureItem: NSMenuItem?
    private var pickerItem: NSMenuItem?

    init(
        onCapture: @escaping () -> Void,
        onPicker: @escaping () -> Void,
        onSettings: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.onCapture = onCapture
        self.onPicker = onPicker
        self.onSettings = onSettings
        self.onQuit = onQuit
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    }

    func install() {
        if let image = NSImage(
            systemSymbolName: "camera.viewfinder",
            accessibilityDescription: "ushot"
        ) {
            statusItem.button?.image = image
        } else {
            statusItem.button?.title = "◲"
        }

        let menu = NSMenu()
        let capture = NSMenuItem(title: "截图", action: #selector(captureClicked), keyEquivalent: "")
        capture.target = self
        menu.addItem(capture)
        self.captureItem = capture

        let picker = NSMenuItem(title: "取色器", action: #selector(pickerClicked), keyEquivalent: "")
        picker.target = self
        menu.addItem(picker)
        self.pickerItem = picker

        menu.addItem(.separator())
        let settings = NSMenuItem(title: "设置…", action: #selector(settingsClicked), keyEquivalent: ",")
        settings.keyEquivalentModifierMask = [.command]
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 ushot", action: #selector(quitClicked), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        updateShortcuts()
    }

    /// Show the current shortcuts next to the menu items.
    func updateShortcuts() {
        apply(Preferences.captureHotkey, to: captureItem)
        apply(Preferences.pickerHotkey, to: pickerItem)
    }

    private func apply(_ hotkey: Hotkey, to item: NSMenuItem?) {
        let label = hotkey.keyLabel
        if label.count == 1, let character = label.first, character.isLetter || character.isNumber {
            item?.keyEquivalent = String(character).lowercased()
            item?.keyEquivalentModifierMask = hotkey.modifiers
        } else {
            item?.keyEquivalent = ""
            item?.keyEquivalentModifierMask = []
        }
    }

    @objc private func captureClicked() { onCapture() }
    @objc private func pickerClicked() { onPicker() }
    @objc private func settingsClicked() { onSettings() }
    @objc private func quitClicked() { onQuit() }
}
