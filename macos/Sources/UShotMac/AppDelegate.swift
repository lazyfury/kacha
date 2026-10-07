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
    private lazy var editor = EditorWindow(pins: pins)
    private var menuBar: MenuBar?
    private var hotkeys: Hotkeys?
    private var windowHotkey: Hotkeys?

    init(options: LaunchOptions) {
        self.options = options
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenu()

        let menuBar = MenuBar(
            onCapture: { [weak self] in self?.startCapture() },
            onWindowCapture: { [weak self] in self?.startWindowCapture() },
            onQuit: { NSApp.terminate(nil) }
        )
        menuBar.install()
        self.menuBar = menuBar

        let regionHotkey = Hotkeys(keyCode: Hotkeys.keyA, id: 1) { [weak self] in
            self?.startCapture()
        }
        regionHotkey.register()
        self.hotkeys = regionHotkey

        let windowHotkey = Hotkeys(keyCode: Hotkeys.keyW, id: 2) { [weak self] in
            self?.startWindowCapture()
        }
        windowHotkey.register()
        self.windowHotkey = windowHotkey

        overlays.onConfirm = { [weak self] session in
            self?.editor.show(session: session)
        }
        overlays.onCancel = { _ in }
        overlays.onPick = { [weak self] session, window in
            self?.captureWindow(window, session: session)
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

    private func installMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()

        let capture = NSMenuItem(
            title: "开始截图",
            action: #selector(startCapture),
            keyEquivalent: "a"
        )
        capture.keyEquivalentModifierMask = [.command, .shift]
        capture.target = self
        appMenu.addItem(capture)

        let windowCapture = NSMenuItem(
            title: "窗口截图",
            action: #selector(startWindowCapture),
            keyEquivalent: "w"
        )
        windowCapture.keyEquivalentModifierMask = [.command, .shift]
        windowCapture.target = self
        appMenu.addItem(windowCapture)

        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit ushot",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
    }

    // MARK: - Capture

    /// Freeze every display and raise the overlay panels (region mode).
    @objc private func startCapture() {
        startCaptureFlow(pick: false)
    }

    /// Window-pick mode: the overlay outlines windows; a click captures one.
    @objc private func startWindowCapture() {
        startCaptureFlow(pick: true)
    }

    private func startCaptureFlow(pick: Bool) {
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
                self.overlays.show(session: session, windows: result.windows, pick: pick)
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
