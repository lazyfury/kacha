// The settings window: a SwiftUI form (Liquid Glass card) hosted in an AppKit
// window. The hotkey recorder stays AppKit and is embedded.

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

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 380),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "ushot 设置"
        window.isReleasedWhenClosed = false
        window.delegate = self

        let root = SettingsRootView(
            onHotkeyChange: { [weak self] in self?.onHotkeyChange?() }
        )
        window.contentView = NSHostingView(rootView: root)

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
