// The settings window: a SwiftUI grouped form hosted in an AppKit window. The
// hotkey recorder stays AppKit and is embedded.

import AppKit
import SwiftUI

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
        window.title = "ushot 设置"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.isReleasedWhenClosed = false
        window.delegate = self
        // Same seamless, full-size chrome as the editor window.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
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
