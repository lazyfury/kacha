// The menu-bar item: ushot's entry point when it is not driven from the menu.
//
// The item opens the same capture flow as the app menu / global hotkey.

import AppKit

final class MenuBar {
    private let statusItem: NSStatusItem
    private let onCapture: () -> Void
    private let onWindowCapture: () -> Void
    private let onQuit: () -> Void

    init(
        onCapture: @escaping () -> Void,
        onWindowCapture: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.onCapture = onCapture
        self.onWindowCapture = onWindowCapture
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
        let capture = NSMenuItem(
            title: "开始截图",
            action: #selector(captureClicked),
            keyEquivalent: "a"
        )
        capture.keyEquivalentModifierMask = [.command, .shift]
        capture.target = self
        menu.addItem(capture)

        let windowCapture = NSMenuItem(
            title: "窗口截图",
            action: #selector(windowCaptureClicked),
            keyEquivalent: "w"
        )
        windowCapture.keyEquivalentModifierMask = [.command, .shift]
        windowCapture.target = self
        menu.addItem(windowCapture)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 ushot", action: #selector(quitClicked), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    @objc private func captureClicked() {
        onCapture()
    }

    @objc private func windowCaptureClicked() {
        onWindowCapture()
    }

    @objc private func quitClicked() {
        onQuit()
    }
}
