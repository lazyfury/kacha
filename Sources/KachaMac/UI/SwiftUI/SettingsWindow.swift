// The settings window: a SwiftUI view hosted in an AppKit window. The chrome is
// seamless (full-size content, transparent title-less titlebar) so the SwiftUI
// content draws the System-Settings-style top bar and footer itself.

import AppKit
import SwiftUI

@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    /// Called after a hotkey changed, so the shell can re-register them.
    var onHotkeyChange: (() -> Void)?

    var isOpen: Bool { window != nil }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let root = SettingsRootView(
            onHotkeyChange: { [weak self] in self?.onHotkeyChange?() }
        )
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.title = "设置"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        WindowChrome.own(window)
        window.delegate = self
        // Seamless chrome: the SwiftUI content supplies the title and footer.
        WindowChrome.seamless(window)
        window.setContentSize(hosting.view.fittingSize)

        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }

    /// Debug: close the settings window (the `--smoke-settings` path).
    func close() {
        window?.close()
        window = nil
    }
}
