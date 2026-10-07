// The menu-bar item: kacha's entry point when it is not driven from the menu.

import AppKit

@MainActor
final class MenuBar {
    private let statusItem: NSStatusItem
    private let onCapture: () -> Void
    private let onFullScreen: () -> Void
    private let onPicker: () -> Void
    private let onSettings: () -> Void
    private let onClosePins: () -> Void
    private let onQuit: () -> Void
    private var captureItem: NSMenuItem?
    private var fullScreenItem: NSMenuItem?
    private var pickerItem: NSMenuItem?

    init(
        onCapture: @escaping () -> Void,
        onFullScreen: @escaping () -> Void,
        onPicker: @escaping () -> Void,
        onSettings: @escaping () -> Void,
        onClosePins: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.onCapture = onCapture
        self.onFullScreen = onFullScreen
        self.onPicker = onPicker
        self.onSettings = onSettings
        self.onClosePins = onClosePins
        self.onQuit = onQuit
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    }

    func install() {
        // A slightly larger menu-bar glyph: configure the symbol and let the
        // button scale it up as well as down.
        let configuration = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        if let image = NSImage(
            systemSymbolName: "camera.viewfinder",
            accessibilityDescription: "kacha"
        )?.withSymbolConfiguration(configuration) {
            statusItem.button?.image = image
            statusItem.button?.imageScaling = .scaleProportionallyDown
        } else {
            statusItem.button?.title = "◲"
        }

        let menu = NSMenu()
        let capture = NSMenuItem(title: "截图", action: #selector(captureClicked), keyEquivalent: "")
        capture.target = self
        menu.addItem(capture)
        self.captureItem = capture

        let fullScreen = NSMenuItem(
            title: "全屏截图",
            action: #selector(fullScreenClicked),
            keyEquivalent: ""
        )
        fullScreen.target = self
        menu.addItem(fullScreen)
        self.fullScreenItem = fullScreen

        let picker = NSMenuItem(title: "取色器", action: #selector(pickerClicked), keyEquivalent: "")
        picker.target = self
        menu.addItem(picker)
        self.pickerItem = picker

        menu.addItem(.separator())
        let closePins = NSMenuItem(
            title: "关闭所有钉图",
            action: #selector(closePinsClicked),
            keyEquivalent: ""
        )
        closePins.target = self
        menu.addItem(closePins)

        let settings = NSMenuItem(title: "设置…", action: #selector(settingsClicked), keyEquivalent: ",")
        settings.keyEquivalentModifierMask = [.command]
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 kacha", action: #selector(quitClicked), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        updateShortcuts()
    }

    /// Show the current shortcuts next to the menu items.
    func updateShortcuts() {
        Preferences.captureHotkey.apply(to: captureItem)
        Preferences.fullScreenHotkey.apply(to: fullScreenItem)
        Preferences.pickerHotkey.apply(to: pickerItem)
    }

    @objc private func captureClicked() { onCapture() }
    @objc private func fullScreenClicked() { onFullScreen() }
    @objc private func pickerClicked() { onPicker() }
    @objc private func settingsClicked() { onSettings() }
    @objc private func closePinsClicked() { onClosePins() }
    @objc private func quitClicked() { onQuit() }
}
