// The settings window: the capture and colour-picker hotkeys and
// launch-at-login.

import AppKit

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
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "ushot 设置"
        window.isReleasedWhenClosed = false
        window.delegate = self

        let captureRecorder = HotkeyRecorderView(hotkey: Preferences.captureHotkey)
        captureRecorder.onChange = { [weak self] hotkey in
            Preferences.captureHotkey = hotkey
            self?.onHotkeyChange?()
        }
        let pickerRecorder = HotkeyRecorderView(hotkey: Preferences.pickerHotkey)
        pickerRecorder.onChange = { [weak self] hotkey in
            Preferences.pickerHotkey = hotkey
            self?.onHotkeyChange?()
        }

        let login = NSButton(
            checkboxWithTitle: "开机时启动",
            target: self,
            action: #selector(toggleLogin(_:))
        )
        login.state = LaunchAtLogin.isEnabled ? .on : .off
        login.isEnabled = LaunchAtLogin.isAvailable

        let reset = NSButton(title: "恢复默认快捷键", target: self, action: #selector(resetHotkeys))
        reset.bezelStyle = .rounded

        let grid = NSGridView(views: [
            [Self.label("截图快捷键"), captureRecorder],
            [Self.label("取色器快捷键"), pickerRecorder],
            [Self.label("启动"), login],
            [NSView(), reset],
        ])
        grid.rowSpacing = 12
        grid.columnSpacing = 14
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading

        let content = NSView(frame: window.contentView?.bounds ?? .zero)
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
        ])

        if !LaunchAtLogin.isAvailable {
            let note = Self.note("从 .app 运行时可设置开机启动。")
            content.addSubview(note)
            note.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                note.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 10),
                note.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            ])
        }

        window.contentView = content
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    @objc private func toggleLogin(_ sender: NSButton) {
        let enabled = sender.state == .on
        if let error = LaunchAtLogin.set(enabled) {
            sender.state = enabled ? .off : .on
            let alert = NSAlert()
            alert.messageText = "无法修改开机启动"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    @objc private func resetHotkeys() {
        Preferences.captureHotkey = .default
        Preferences.pickerHotkey = .pickerDefault
        onHotkeyChange?()
        // Reopen so the recorders show the defaults.
        let previous = window
        window = nil
        previous?.close()
        show()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }

    /// Debug: close the settings window (the `--smoke-settings` path).
    func close() {
        window?.close()
        window = nil
    }

    private static func label(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }

    private static func note(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.textColor = .secondaryLabelColor
        field.font = .systemFont(ofSize: 11)
        return field
    }
}
