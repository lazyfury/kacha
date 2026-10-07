// AppKit lifecycle for a menu-bar app.
//
// There is **no persistent window**: ushot lives in the status item and opens
// windows only when it needs to (the freeze-frame overlay, the editor, pinned
// images). That keeps a stray window from covering the app you are trying to
// capture, and matches the design (`LSUIElement` / `.accessory`).
//
// Frames are event-driven: any input schedules one, and while a window wants
// more (a drag, an animation) a `CADisplayLink` drives them. Swift's only jobs
// are the windows, the layers and native event forwarding — the UI is Rust's.

import AppKit
import QuartzCore
import ScreenCaptureKit
import UniformTypeIdentifiers
import UShotNative

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let options: LaunchOptions
    private let overlays = OverlayWindows()
    private let editor = EditorWindow()
    private let pins = PinWindows()
    private var menuBar: MenuBar?
    private var hotkeys: Hotkeys?
    private var windowHotkey: Hotkeys?
    /// A pending one-shot frame (idle input), or nil.
    private var timer: Timer?
    /// Drives frames while a window wants them (macOS 14+).
    private var displayLink: CADisplayLink?
    /// The local event monitor that schedules a frame for any input.
    private var eventMonitor: Any?

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

        if #available(macOS 14.0, *), let link = NSScreen.main?.displayLink(
            target: self,
            selector: #selector(displayTick)
        ) {
            link.add(to: .main, forMode: .common)
            link.isPaused = true
            displayLink = link
        }
        // Every input event passes through this monitor; it schedules a frame,
        // and `runFrame` keeps the display link running while a window wants
        // more frames. It also owns Escape/Return for the overlay (only one
        // borderless panel can be key, so a per-window handler would miss the
        // others).
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .any) { [weak self] event in
            guard let self else { return event }
            if self.overlays.isOpen {
                if event.type == .keyDown, event.keyCode == 53 {
                    self.overlays.close()
                    self.requestFrame()
                    return nil
                }
                if event.type == .keyDown, event.keyCode == 36 || event.keyCode == 76 {
                    ushot_session_confirm(self.overlays.session)
                    self.requestFrame()
                    return nil
                }
            }
            self.requestFrame()
            return event
        }
        requestFrame()

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
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        displayLink?.invalidate()
        displayLink = nil
        timer?.invalidate()
        timer = nil
        overlays.close()
        editor.close()
        pins.closeAll()
    }

    @objc private func displayTick() {
        runFrame()
    }

    private func timerTick() {
        timer = nil
        runFrame()
    }

    private func runFrame() {
        var wants = false
        if overlays.isOpen {
            if overlays.isPicking {
                // The shell owns the hit-test; push the hovered window before the
                // frame so the overlay draws exactly what a click will capture.
                overlays.updateHover(at: NSEvent.mouseLocation, session: overlays.session)
            }
            overlays.frameAll()
            if overlays.isPicking {
                handleWindowPick()
            } else {
                handleRegionConfirm()
            }
            wants = wants || overlays.needsFrame()
        }
        if editor.isOpen {
            editor.frameAll()
            wants = wants || editor.needsFrame()
            handleEditorAction()
        }
        setContinuous(wants)
    }

    /// Ask for a frame as soon as the run loop is free (after the event that
    /// prompted it is dispatched). While the display link is running it will
    /// present at the next refresh anyway.
    private func requestFrame() {
        if let displayLink, !displayLink.isPaused {
            return
        }
        schedule(after: 0)
    }

    private func schedule(after delay: TimeInterval) {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            self?.timerTick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Start or stop the continuous driver (the display link).
    private func setContinuous(_ on: Bool) {
        displayLink?.isPaused = !on
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
                self.overlays.show(
                    displays: result.displays,
                    windows: result.windows,
                    pick: pick
                )
                self.requestFrame()
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

    /// A confirmed region: Rust composed it; open the editor.
    private func handleRegionConfirm() {
        var x: Float = 0
        var y: Float = 0
        var width: Float = 0
        var height: Float = 0
        guard ushot_session_take_selection(overlays.session, &x, &y, &width, &height) == 1 else {
            return
        }
        NSLog("ushot: 选区 x=%g y=%g w=%g h=%g", x, y, width, height)
        let session = overlays.session
        overlays.dismiss()
        editor.show(session: session)
    }

    /// A clicked window: capture it directly (occlusion-safe) into the editor.
    ///
    /// Cropping the frozen desktop would show whatever is on top of the window;
    /// `SCContentFilter(desktopIndependentWindow:)` renders the window itself.
    /// The window was chosen by AppKit's hit-test, so it is the one under the
    /// cursor at the top of the real z-order.
    private func handleWindowPick() {
        guard ushot_session_take_pick(overlays.session) == 1 else {
            return
        }
        guard let window = overlays.hoveredWindow else {
            overlays.close()
            return
        }
        let session = overlays.session
        overlays.dismiss()
        Task { @MainActor in
            do {
                let captured = try await Capture.captureWindow(window)
                captured.bytes.withUnsafeBufferPointer { buffer in
                    ushot_session_set_composed(
                        session,
                        UInt32(captured.width),
                        UInt32(captured.height),
                        buffer.baseAddress,
                        buffer.count
                    )
                }
                self.editor.show(session: session)
                self.requestFrame()
            } catch {
                ushot_session_drop(session)
                self.presentCaptureError(error)
            }
        }
    }

    private func presentCaptureError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "截图失败"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        // This can fire from a global hotkey while another app is frontmost.
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// Carry out the editor's parked toolbar action.
    private func handleEditorAction() {
        switch editor.takeAction() {
        case UInt32(USHOT_ACTION_COPY):
            if let png = editor.actionPNG() {
                copyToPasteboard(png)
            }
            editor.actionDone()
        case UInt32(USHOT_ACTION_SAVE):
            if let png = editor.actionPNG() {
                savePNG(png)
            }
            editor.actionDone()
        case UInt32(USHOT_ACTION_PIN):
            if let png = editor.actionPNG() {
                pins.pin(png)
            }
            editor.actionDone()
        case UInt32(USHOT_ACTION_CLOSE):
            editor.close()
        default:
            break
        }
    }

    private func copyToPasteboard(_ png: Data) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
    }

    private func savePNG(_ png: Data) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = Self.timestamp() + ".png"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try png.write(to: url)
            } catch {
                presentError("保存失败", error.localizedDescription)
            }
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "ushot-" + formatter.string(from: Date())
    }

    private func presentError(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// Debug (`--smoke-export`): inject a synthetic capture, confirm it, open
    /// the editor, copy the result, and check the clipboard — the whole output
    /// path with no screen recording and no user input.
    private func runExportSmoke() {
        let session = ushot_session_new()
        var rgba = [UInt8](repeating: 0, count: 64 * 64 * 4)
        for index in stride(from: 0, to: rgba.count, by: 4) {
            rgba[index] = 255
            rgba[index + 3] = 255
        }
        rgba.withUnsafeBufferPointer { buffer in
            ushot_display_image(session, 1, 0, 0, 64, 64, 1.0, buffer.baseAddress, buffer.count)
        }
        ushot_session_set_selection(session, 0, 0, 64, 64)
        ushot_session_confirm(session)
        editor.show(session: session)
        requestFrame()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            self.editor.requestAction(UInt32(USHOT_ACTION_COPY))
            self.requestFrame()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                let copied = NSPasteboard.general.data(forType: .png) != nil
                FileHandle.standardError.write(
                    Data("ushot smoke-export copy: \(copied ? "ok" : "FAILED")\n".utf8)
                )
                self.editor.smokeClose()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    exit(copied ? 0 : 1)
                }
            }
        }
    }

    /// Debug (`--smoke-editor`): open the editor on an empty session and close
    /// it, exercising the teardown path with no screen-recording permission.
    private func runEditorSmoke() {
        let session = ushot_session_new()
        editor.show(session: session)
        requestFrame()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            self.editor.smokeClose()
            self.requestFrame()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSApp.terminate(nil)
            }
        }
    }
}
