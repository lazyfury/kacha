// AppKit lifecycle for a menu-bar app.
//
// There is no persistent window and no render loop: the overlay and the editor
// redraw on demand. kacha lives in the status item and opens windows only when
// it needs to.

import AppKit
import CoreGraphics
import CoreText
import ScreenCaptureKit

@MainActor
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
    private var fullScreenMenuItem: NSMenuItem?

    init(options: LaunchOptions) {
        self.options = options
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenu()

        let menuBar = MenuBar(
            onCapture: { [weak self] in self?.startCapture() },
            onFullScreen: { [weak self] in self?.startFullScreenCapture() },
            onPicker: { [weak self] in self?.startColorPicker() },
            onSettings: { [weak self] in self?.settings.show() },
            onClosePins: { [weak self] in self?.pins.closeAll() },
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
            ShotSound.playIfEnabled()
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
        if options.smokeOCR {
            runOCRSmoke()
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
            Hotkeys.Binding(id: 3, hotkey: Preferences.fullScreenHotkey) { [weak self] in
                self?.startFullScreenCapture()
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

        let fullScreen = NSMenuItem(
            title: "全屏截图",
            action: #selector(startFullScreenCapture),
            keyEquivalent: ""
        )
        fullScreen.target = self
        appMenu.addItem(fullScreen)
        self.fullScreenMenuItem = fullScreen

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
            withTitle: "退出 kacha",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
        updateMenuShortcuts()
    }

    private func updateMenuShortcuts() {
        Preferences.captureHotkey.apply(to: captureMenuItem)
        Preferences.pickerHotkey.apply(to: pickerMenuItem)
        Preferences.fullScreenHotkey.apply(to: fullScreenMenuItem)
    }

    @objc private func openSettings() {
        settings.show()
    }

    // MARK: - Capture

    /// Freeze every display and raise the unified overlay (drag a region, click a
    /// window or the desktop). Shared by the capture and colour-picker entries.
    private func startOverlay(mode: OverlayMode) {
        guard ScreenPermission.request() else {
            presentPermissionAlert()
            return
        }
        Task { @MainActor in
            guard let result = await self.freezeDisplays() else { return }
            let session = Self.session(from: result, mode: mode)
            self.overlays.show(session: session, windows: result.windows)
        }
    }

    @objc private func startCapture() {
        startOverlay(mode: .capture)
    }

    @objc private func startColorPicker() {
        startOverlay(mode: .colorPicker)
    }

    /// Freeze every display and send the display under the cursor straight to
    /// the editor, skipping the overlay.
    @objc private func startFullScreenCapture() {
        guard ScreenPermission.request() else {
            presentPermissionAlert()
            return
        }
        Task { @MainActor in
            guard let result = await self.freezeDisplays() else { return }
            guard
                let display = Self.display(under: NSEvent.mouseLocation, in: result.displays)
                    ?? result.displays.first
            else {
                self.presentCaptureError(CaptureError.noDisplays)
                return
            }
            let session = Self.session(from: result)
            session.composed = Compose.composed(from: display.image)
            ShotSound.playIfEnabled()
            self.editor.show(session: session)
        }
    }

    /// Freeze every display, showing the error alert on failure.
    private func freezeDisplays() async -> CaptureResult? {
        do {
            return try await Capture.frozenDisplays()
        } catch {
            presentCaptureError(error)
            return nil
        }
    }

    /// A session over `result`'s frozen displays, in the given overlay mode.
    private static func session(
        from result: CaptureResult,
        mode: OverlayMode = .capture
    ) -> CaptureSession {
        let session = CaptureSession()
        session.mode = mode
        for display in result.displays {
            session.setDisplay(display)
        }
        return session
    }

    /// The captured display whose screen contains `point` (AppKit global coords).
    private static func display(
        under point: CGPoint,
        in displays: [CapturedDisplay]
    ) -> CapturedDisplay? {
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        guard
            let number = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? NSNumber
        else {
            return nil
        }
        return displays.first { $0.displayID == number.uint32Value }
    }

    /// A clicked window: capture it directly (occlusion-safe) into the editor.
    private func captureWindow(_ window: SCWindow, session: CaptureSession) {
        Task { @MainActor in
            do {
                let image = try await Capture.captureWindow(window)
                session.composed = Compose.composed(from: image)
                ShotSound.playIfEnabled()
                self.editor.show(session: session)
            } catch {
                self.presentCaptureError(error)
            }
        }
    }

    private func presentPermissionAlert() {
        let response = presentAlert(
            "需要「屏幕录制」权限",
            informative: "请在「系统设置 › 隐私与安全性 › 屏幕录制」里勾选 kacha，然后重新启动应用。",
            buttons: ["打开系统设置", "稍后"]
        )
        if response == .alertFirstButtonReturn {
            ScreenPermission.openSystemSettings()
        }
    }

    private func presentCaptureError(_ error: Error) {
        _ = presentAlert("截图失败", informative: error.localizedDescription)
    }

    /// Show a modal alert, activating the app first. Returns the chosen button.
    @discardableResult
    private func presentAlert(
        _ message: String,
        informative: String,
        style: NSAlert.Style = .warning,
        buttons: [String] = ["好"]
    ) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = informative
        alert.alertStyle = style
        for button in buttons {
            alert.addButton(withTitle: button)
        }
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal()
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
                Export.copyPNG(data)
            }
            let copied = NSPasteboard.general.data(forType: .png) != nil
            FileHandle.standardError.write(
                Data("kacha smoke-export copy: \(copied ? "ok" : "FAILED")\n".utf8)
            )
            self.editor.close()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                exit(copied ? 0 : 1)
            }
        }
    }

    /// Debug (`--smoke-ocr`): render known text, recognize it with Vision and
    /// check the result — the OCR path with no screen-recording permission.
    private func runOCRSmoke() {
        guard let image = Self.textImage("KACHA OCR 7788") else {
            FileHandle.standardError.write(Data("kacha smoke-ocr: FAILED (render)\n".utf8))
            exit(1)
        }
        Task { @MainActor in
            let transcript = await OCR.analyze(image)?.transcript ?? ""
            let normalized = transcript.uppercased()
            let ok = normalized.contains("KACHA") && normalized.contains("7788")
            let found = transcript.replacingOccurrences(of: "\n", with: " | ")
            FileHandle.standardError.write(
                Data("kacha smoke-ocr: \(ok ? "ok" : "FAILED") [\(found)]\n".utf8)
            )
            exit(ok ? 0 : 1)
        }
    }

    /// A white bitmap with `text` in black, for the OCR smoke.
    private static func textImage(_ text: String) -> CGImage? {
        let width = 800
        let height = 200
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard
            let ctx = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            return nil
        }
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 72, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            kCTForegroundColorAttributeName as NSAttributedString.Key:
                CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1),
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attributed)
        ctx.textPosition = CGPoint(x: 40, y: 70)
        CTLineDraw(line, ctx)
        return ctx.makeImage()
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
