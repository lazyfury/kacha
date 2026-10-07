// The menu-bar item: ushot's entry point when it is not driven from the menu.

import AppKit

final class MenuBar {
    private let statusItem: NSStatusItem
    private let onCapture: () -> Void
    private let onSettings: () -> Void
    private let onQuit: () -> Void
    private var captureItem: NSMenuItem?

    init(
        onCapture: @escaping () -> Void,
        onSettings: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.onCapture = onCapture
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

        let settings = NSMenuItem(title: "设置…", action: #selector(settingsClicked), keyEquivalent: ",")
        settings.keyEquivalentModifierMask = [.command]
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 ushot", action: #selector(quitClicked), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        updateCaptureShortcut(Preferences.captureHotkey)
    }

    /// Show the current capture shortcut next to the menu item.
    func updateCaptureShortcut(_ hotkey: Hotkey) {
        let label = hotkey.keyLabel
        if label.count == 1, let character = label.first, character.isLetter || character.isNumber {
            captureItem?.keyEquivalent = String(character).lowercased()
            captureItem?.keyEquivalentModifierMask = hotkey.modifiers
        } else {
            captureItem?.keyEquivalent = ""
            captureItem?.keyEquivalentModifierMask = []
        }
    }

    @objc private func captureClicked() { onCapture() }
    @objc private func settingsClicked() { onSettings() }
    @objc private func quitClicked() { onQuit() }
}
