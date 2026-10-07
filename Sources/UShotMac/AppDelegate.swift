// AppKit lifecycle for a menu-bar app.
//
// There is no persistent window and no render loop: the overlay and the editor
// redraw on demand. ushot lives in the status item and opens windows only when
// it needs to.

import AppKit
import CoreGraphics
import ScreenCaptureKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let options: LaunchOptions
    private let overlays = OverlayController()
    private let pins = PinWindows()
    private let settings = SettingsWindow()
    private lazy var editor = EditorWindow(pins: pins)
    private var menuBar: MenuBar?
    private var hotkeys: Hotkeys?
    private var captureMenuItem: NSMenuItem?
    private var pickerMenuItem: NSMenuItem?

    init(options: LaunchOptions) {
        self.options = options
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenu()

        let menuBar = MenuBar(
            onCapture: { [weak self] in self?.startCapture() },
            onPicker: { [weak self] in self?.startColorPicker() },
            onSettings: { [weak self] in self?.settings.show() },
            onQuit: { NSApp.terminate(nil) }
        )
        menuBar.install()
        self.menuBar = menuBar

        let hotkeys = Hotkeys()
        self.hotkeys = hotkeys
        registerHotkeys()

        settings.onHotkeyChange = { [weak self] in
            self?.registerHotkeys()
            self?.menuBar?.updateShortcuts()
            self?.updateMenuShortcuts()
        }

        overlays.onConfirm = { [weak self] session in
            self?.editor.show(session: session)
        }
        overlays.onCancel = { _ in }
        overlays.onPick = { [weak self] session, window in
            self?.captureWindow(window, session: session)
        }

        if options.smokeSettings {
            runSettingsSmoke()
        }
        if options.smokeEditor {
            runEditorSmoke()
        }
        if options.smokeExport {
            runExportSmoke()
        }
    }

    /// A menu-bar app keeps running after its last window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        overlays.close()
        editor.close()
        pins.closeAll()
    }

    private func registerHotkeys() {
        hotkeys?.set([
            Hotkeys.Binding(id: 1, hotkey: Preferences.captureHotkey) { [weak self] in
                self?.startCapture()
            },
            Hotkeys.Binding(id: 2, hotkey: Preferences.pickerHotkey) { [weak self] in
                self?.startColorPicker()
            },
        ])
    }

    private func installMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()

        let capture = NSMenuItem(title: "截图", action: #selector(startCapture), keyEquivalent: "")
        capture.target = self
        appMenu.addItem(capture)
        self.captureMenuItem = capture

        let picker = NSMenuItem(title: "取色器", action: #selector(startColorPicker), keyEquivalent: "")
        picker.target = self
        appMenu.addItem(picker)
        self.pickerMenuItem = picker

        let settings = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settings.keyEquivalentModifierMask = [.command]
        settings.target = self
        appMenu.addItem(settings)

        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "退出 ushot",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
        updateMenuShortcuts()
    }

    private func updateMenuShortcuts() {
        apply(Preferences.captureHotkey, to: captureMenuItem)
        apply(Preferences.pickerHotkey, to: pickerMenuItem)
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

    @objc private func openSettings() {
        settings.show()
    }

    // MARK: - Capture

    /// Freeze every display and raise the unified overlay (drag a region, click a
    /// window or the desktop).
    @objc private func startCapture() {
        guard ScreenPermission.request() else {
            presentPermissionAlert()
            return
        }
        Task { @MainActor in
            do {
                let result = try await Capture.frozenDisplays()
                let session = CaptureSession()
                for display in result.displays {
                    session.setDisplay(display)
                }
                self.overlays.show(session: session, windows: result.windows)
            } catch {
                self.presentCaptureError(error)
            }
        }
    }

    /// Freeze every display and open the colour picker.
    @objc private func startColorPicker() {
        guard ScreenPermission.request() else {
            presentPermissionAlert()
            return
        }
        Task { @MainActor in
            do {
                let result = try await Capture.frozenDisplays()
                let session = CaptureSession()
                session.mode = .colorPicker
                for display in result.displays {
                    session.setDisplay(display)
                }
                self.overlays.show(session: session, windows: result.windows)
            } catch {
                self.presentCaptureError(error)
            }
        }
    }

    /// A clicked window: capture it directly (occlusion-safe) into the editor.
    private func captureWindow(_ window: SCWindow, session: CaptureSession) {
        Task { @MainActor in
            do {
                let image = try await Capture.captureWindow(window)
                session.composed = Compose.composed(from: image)
                self.editor.show(session: session)
            } catch {
                self.presentCaptureError(error)
            }
        }
    }

    private func presentPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "需要「屏幕录制」权限"
        alert.informativeText =
            "请在「系统设置 › 隐私与安全性 › 屏幕录制」里勾选 ushot，然后重新启动应用。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            ScreenPermission.openSystemSettings()
        }
    }

    private func presentCaptureError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "截图失败"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - Smoke tests (no screen-recording permission)

    /// Debug (`--smoke-settings`): open and close the settings window.
    private func runSettingsSmoke() {
        settings.show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.settings.close()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                NSApp.terminate(nil)
            }
        }
    }

    /// Debug (`--smoke-editor`): open the editor on a synthetic image and close
    /// it, exercising the teardown path.
    private func runEditorSmoke() {
        let session = Self.syntheticSession()
        editor.show(session: session)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.editor.close()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSApp.terminate(nil)
            }
        }
    }

    /// Debug (`--smoke-export`): open the editor on a synthetic image, export it,
    /// and check the clipboard — the whole output path with no permission.
    private func runExportSmoke() {
        let session = Self.syntheticSession()
        editor.show(session: session)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            if let data = self.editor.exportForSmoke() {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setData(data, forType: .png)
            }
            let copied = NSPasteboard.general.data(forType: .png) != nil
            FileHandle.standardError.write(
                Data("ushot smoke-export copy: \(copied ? "ok" : "FAILED")\n".utf8)
            )
            self.editor.close()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                exit(copied ? 0 : 1)
            }
        }
    }

    /// A 64×64 red composed image, for the smoke tests.
    private static func syntheticSession() -> CaptureSession {
        let session = CaptureSession()
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        if let ctx = CGContext(
            data: nil,
            width: 64,
            height: 64,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) {
            ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            if let image = ctx.makeImage() {
                session.composed = Compose.composed(from: image)
            }
        }
        return session
    }
}
