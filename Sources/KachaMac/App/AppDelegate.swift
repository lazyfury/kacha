// AppKit lifecycle for a menu-bar app.
//
// There is no persistent window and no render loop: the overlay and the editor
// redraw on demand. kacha lives in the status item and opens windows only when
// it needs to.

import AppKit
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreText
import ScreenCaptureKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let options: LaunchOptions
    private let overlays = OverlayController()
    private let pins = PinWindows()
    private let settings = SettingsWindow()
    private let countdown = CountdownHUD()
    private let recordingBar = RecordingBar()
    private lazy var editor = EditorWindow(pins: pins)
    private var menuBar: MenuBar?
    private var hotkeys: Hotkeys?
    /// The active recording session (macOS 15+); held as `AnyObject` so the
    /// property itself does not require macOS 15.
    private var recordingSession: AnyObject?
    private var micMuted = false
    /// The microphone state chosen during the pre-recording countdown.
    private var countdownMicMuted = false
    /// True from the moment a recording target is confirmed until it ends, so a
    /// second recording session cannot start on top of it.
    private var recordingActive = false
    /// True while a quit is waiting for the recording to finish and be saved.
    private var terminating = false
    private var captureMenuItem: NSMenuItem?
    private var pickerMenuItem: NSMenuItem?
    private var fullScreenMenuItem: NSMenuItem?
    private var recordMenuItem: NSMenuItem?

    init(options: LaunchOptions) {
        self.options = options
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenu()

        let menuBar = MenuBar(
            onCapture: { [weak self] in self?.startCapture() },
            onDelayedCapture: { [weak self] seconds in self?.startDelayedCapture(seconds: seconds) },
            onFullScreen: { [weak self] in self?.startFullScreenCapture() },
            onRecord: { [weak self] in self?.startRecording() },
            onPicker: { [weak self] in self?.startColorPicker() },
            onViewer: { [weak self] in self?.openViewer() },
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
        overlays.onSave = { [weak self] session in
            ShotSound.playIfEnabled()
            self?.saveSession(session)
        }
        overlays.onCancel = { _ in }
        overlays.onPick = { [weak self] session, window in
            self?.captureWindow(window, session: session)
        }
        overlays.onRecord = { [weak self] _, target in
            guard let self, !self.recordingActive else { return }
            self.recordingActive = true
            self.beginRecording(target)
        }
        overlays.onError = { [weak self] message in
            self?.presentAlert("无法录制", informative: message, style: .informational)
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
        if options.smokeViewer {
            runViewerSmoke()
        }
        if options.smokeBarcode {
            runBarcodeSmoke()
        }
        if options.smokeRecord {
            runRecordSmoke()
        }
    }

    /// A menu-bar app keeps running after its last window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Quitting mid-recording would otherwise lose it (and leak temp files):
    /// offer to stop and save first. `.terminateLater` blocks the quit until the
    /// file is placed; `finishRecording` calls `reply` when it is done.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard recordingActive, #available(macOS 15.0, *),
            let session = recordingSession as? RecordingSession
        else {
            return .terminateNow
        }
        if session.isFinishing {
            // A stop / cancel is already in flight; just wait for it.
            terminating = true
            return .terminateLater
        }
        let response = presentAlert(
            "正在录制",
            informative: "退出会丢失当前录制。要先停止并保存吗？",
            style: .warning,
            buttons: ["停止并保存", "丢弃并退出", "取消"]
        )
        switch response {
        case .alertFirstButtonReturn:
            terminating = true
            session.stop()
            return .terminateLater
        case .alertSecondButtonReturn:
            session.abort()
            recordingSession = nil
            recordingActive = false
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Finalizing a recording needs the async pipeline, which will not run
        // during quit; abort it and drop the temp files instead of leaking them.
        if #available(macOS 15.0, *), let session = recordingSession as? RecordingSession {
            session.abort()
        }
        recordingSession = nil
        recordingActive = false
        countdown.cancel()
        recordingBar.close()
        overlays.close()
        editor.close()
        pins.closeAll()
    }

    private func registerHotkeys() {
        let failed = hotkeys?.set([
            Hotkeys.Binding(id: 1, name: "截图", hotkey: Preferences.captureHotkey) { [weak self] in
                self?.startCapture()
            },
            Hotkeys.Binding(id: 2, name: "取色器", hotkey: Preferences.pickerHotkey) { [weak self] in
                self?.startColorPicker()
            },
            Hotkeys.Binding(id: 3, name: "全屏截图", hotkey: Preferences.fullScreenHotkey) {
                [weak self] in
                self?.startFullScreenCapture()
            },
            Hotkeys.Binding(id: 4, name: "录制屏幕", hotkey: Preferences.recordHotkey) {
                [weak self] in
                self?.startRecording()
            },
        ]) ?? []
        guard !failed.isEmpty else { return }
        presentAlert(
            "快捷键注册失败",
            informative: "\(failed.joined(separator: "、"))已被其他应用占用，请在设置里换一个组合键。",
            style: .warning
        )
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

        let record = NSMenuItem(
            title: "录制屏幕",
            action: #selector(startRecording),
            keyEquivalent: ""
        )
        record.target = self
        appMenu.addItem(record)
        self.recordMenuItem = record

        let picker = NSMenuItem(title: "取色器", action: #selector(startColorPicker), keyEquivalent: "")
        picker.target = self
        appMenu.addItem(picker)
        self.pickerMenuItem = picker

        let viewer = NSMenuItem(title: "看图", action: #selector(openViewer), keyEquivalent: "")
        viewer.target = self
        appMenu.addItem(viewer)

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
        Preferences.recordHotkey.apply(to: recordMenuItem)
    }

    @objc private func openSettings() {
        settings.show()
    }

    @objc private func openViewer() {
        editor.showViewer()
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

    /// Start a capture after `seconds` (0 = now), showing a countdown first.
    private func startDelayedCapture(seconds: Int) {
        Preferences.delaySeconds = seconds
        menuBar?.updateShortcuts()
        guard ScreenPermission.request() else {
            presentPermissionAlert()
            return
        }
        countdown.start(seconds: seconds, onCancel: {}) { [weak self] in
            self?.startOverlay(mode: .capture)
        }
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

    /// Start screen recording: freeze, pick a region / window / display, then
    /// record. Requires macOS 15 (`SCRecordingOutput`).
    @objc private func startRecording() {
        guard #available(macOS 15.0, *) else {
            presentAlert(
                "需要 macOS 15",
                informative: "录屏使用系统的 SCRecordingOutput，需要 macOS 15 或更新版本。"
            )
            return
        }
        // One session at a time.
        guard !recordingActive else { return }
        startOverlay(mode: .record)
    }

    /// Begin recording `target`, showing the control bar until it stops.
    private func beginRecording(_ target: RecordingTarget) {
        guard #available(macOS 15.0, *) else { return }
        let config = Preferences.recordingConfig
        let micAvailable = config.audio.capturesMicrophone && MicRecorder.isSupported
        countdownMicMuted = false
        countdown.start(
            seconds: config.countdown,
            micAvailable: micAvailable,
            micMuted: false,
            onToggleMic: { [weak self] in
                guard let self else { return }
                self.countdownMicMuted.toggle()
                self.countdown.setMicMuted(self.countdownMicMuted)
            },
            onCancel: { [weak self] in
                // The record session was reserved before the countdown; release
                // it so another recording can start.
                self?.recordingActive = false
            },
            onFinish: { [weak self] in
                self?.startRecordingNow(
                    target,
                    config: config,
                    micMuted: self?.countdownMicMuted ?? false
                )
            }
        )
    }

    private func startRecordingNow(
        _ target: RecordingTarget,
        config: RecordingConfig,
        micMuted: Bool
    ) {
        guard #available(macOS 15.0, *) else { return }
        let session = RecordingSession(target: target, config: config, micMuted: micMuted)
        self.recordingSession = session
        self.micMuted = micMuted
        session.onFinish = { [weak self] result in
            self?.finishRecording(result)
        }
        session.onWarning = { [weak self] message in
            self?.presentAlert("录制提示", informative: message, style: .informational)
        }

        Task { @MainActor in
            do {
                try await session.start()
            } catch {
                self.recordingSession = nil
                self.recordingActive = false
                self.presentCaptureError(error)
                return
            }
            self.menuBar?.setRecording(true)
            self.recordMenuItem?.title = "正在录制…"
            self.recordMenuItem?.isEnabled = false

            self.recordingBar.onStop = {
                // Switch to "正在保存…" immediately: stop() then joins / muxes the
                // segments, which can take a while for a long recording.
                self.recordingBar.setSaving(true)
                session.stop()
            }
            self.recordingBar.onCancel = { session.cancel() }
            self.recordingBar.onToggleMic = {
                self.micMuted.toggle()
                session.setMicMuted(self.micMuted)
                self.recordingBar.setMicMuted(self.micMuted)
            }
            self.recordingBar.onTogglePause = {
                Task { @MainActor in
                    let ok = await session.togglePause()
                    self.recordingBar.setPaused(session.isPaused)
                    if !ok {
                        self.presentAlert(
                            "无法继续录制",
                            informative: "恢复录制失败，请停止并保存已录内容。",
                            style: .warning
                        )
                    }
                }
            }
            self.recordingBar.setMicMuted(micMuted)
            self.recordingBar.setPaused(false)
            self.recordingBar.show(micAvailable: session.micActive, elapsed: { session.elapsed })
        }
    }

    /// Report a finished recording and place the file.
    private func finishRecording(_ result: Result<URL, Error>) {
        recordingBar.onStop = nil
        recordingBar.onCancel = nil
        recordingBar.onToggleMic = nil
        recordingBar.onTogglePause = nil
        if #available(macOS 15.0, *), let session = recordingSession as? RecordingSession {
            session.onWarning = nil
        }
        self.recordingSession = nil
        self.recordingActive = false
        menuBar?.setRecording(false)
        recordMenuItem?.title = "录制屏幕"
        recordMenuItem?.isEnabled = true

        switch result {
        case .success(let url):
            // The segments are already joined; placing the file can still take a
            // moment (a cross-volume move or the save panel), so keep the bar's
            // "正在保存…" state up until it lands. The move is off the main
            // thread; only the save panel runs on it.
            Task { @MainActor in
                let final = await Export.saveMovieForRecording(at: url)
                self.recordingBar.close()
                if self.terminating {
                    self.replyTerminationIfNeeded()
                } else if let final {
                    self.presentRecordingSaved(final)
                }
            }
        case .failure(let error):
            recordingBar.close()
            let wasTerminating = terminating
            replyTerminationIfNeeded()
            if wasTerminating || isCancellation(error) { return }
            presentCaptureError(error)
        }
    }

    /// Finish a pending quit (`applicationShouldTerminate` returned
    /// `.terminateLater`).
    private func replyTerminationIfNeeded() {
        guard terminating else { return }
        terminating = false
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    private func isCancellation(_ error: Error) -> Bool {
        if case RecordingError.cancelled = error { return true }
        return false
    }

    private func presentRecordingSaved(_ url: URL) {
        let response = presentAlert(
            "录制完成",
            informative: url.path,
            style: .informational,
            buttons: ["在 Finder 显示", "好"]
        )
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([url])
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

    /// Save a confirmed capture. With a save directory configured (Settings) the
    /// PNG is written straight there; otherwise a save panel is shown.
    private func saveSession(_ session: CaptureSession) {
        guard
            let image = session.composed?.image,
            let data = PNG.encode(image)
        else {
            return
        }
        Export.savePNG(
            data,
            suggestedName: Export.timestampedName(),
            directory: Preferences.saveDirectory
        )
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

    /// Debug (`--smoke-viewer`): open the empty viewer, load an image into it
    /// and export — the empty-window and drag-and-drop load path.
    private func runViewerSmoke() {
        editor.showViewer()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, let image = Self.syntheticImage() else {
                exit(1)
            }
            self.editor.loadForSmoke(image)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                let ok = self.editor.exportForSmoke() != nil
                FileHandle.standardError.write(
                    Data("kacha smoke-viewer load: \(ok ? "ok" : "FAILED")\n".utf8)
                )
                self.editor.close()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    exit(ok ? 0 : 1)
                }
            }
        }
    }

    /// Debug (`--smoke-barcode`): open the editor on a generated QR, decode it
    /// and check the payload — the barcode path with no screen-recording
    /// permission.
    private func runBarcodeSmoke() {
        guard let qr = Self.qrImage("KACHA-7788") else {
            FileHandle.standardError.write(Data("kacha smoke-barcode: FAILED (render)\n".utf8))
            exit(1)
        }
        editor.show(session: Self.syntheticSession(image: qr))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.editor.detectBarcodesForSmoke { codes in
                let ok = codes.contains { $0.payload == "KACHA-7788" }
                let found = codes.map(\.payload).joined(separator: " | ")
                FileHandle.standardError.write(
                    Data("kacha smoke-barcode: \(ok ? "ok" : "FAILED") [\(found)]\n".utf8)
                )
                self?.editor.close()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    exit(ok ? 0 : 1)
                }
            }
        }
    }

    /// Debug (`--smoke-record`): open the recording control bar, flip it into
    /// the saving state and close it — the panel lifecycle with no real capture.
    private func runRecordSmoke() {
        recordingBar.show(micAvailable: true, elapsed: { 5 })
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.recordingBar.setSaving(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.recordingBar.close()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    FileHandle.standardError.write(Data("kacha smoke-record: ok\n".utf8))
                    exit(0)
                }
            }
        }
    }

    /// A QR code bitmap via Core Image, for the barcode smoke.
    private static func qrImage(_ payload: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }

    /// A composed session over `image`, for the smoke tests.
    private static func syntheticSession(image: CGImage) -> CaptureSession {
        let session = CaptureSession()
        if let composed = Compose.composed(from: image) {
            session.composed = composed
        }
        return session
    }

    /// A 64×64 red composed image, for the smoke tests.
    private static func syntheticSession() -> CaptureSession {
        let session = CaptureSession()
        if let image = syntheticImage(), let composed = Compose.composed(from: image) {
            session.composed = composed
        }
        return session
    }

    /// A 64×64 red bitmap, for the smoke tests.
    private static func syntheticImage() -> CGImage? {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard
            let ctx = CGContext(
                data: nil,
                width: 64,
                height: 64,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            return nil
        }
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        return ctx.makeImage()
    }
}
