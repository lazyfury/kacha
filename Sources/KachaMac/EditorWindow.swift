// The editor window: a SwiftUI host (Liquid Glass toolbar) over the AppKit
// canvas. Closing it (red button or ⌘W) tears everything down.

import AppKit
import SwiftUI

final class EditorWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var canvas: EditorCanvasView?
    private var state: EditorState?
    private var session: CaptureSession?
    private let pins: PinWindows

    init(pins: PinWindows) {
        self.pins = pins
    }

    var isOpen: Bool { window != nil }

    /// Open an editor for `session` (the composed image lives in it).
    func show(session: CaptureSession) {
        close()

        let composed = session.composed
        let imageSize = composed.map { CGSize(width: $0.width, height: $0.height) }
            ?? CGSize(width: 900, height: 600)
        let visible = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let contentSize = CGSize(
            width: min(max(imageSize.width + 32, 640), visible.width - 40),
            height: min(max(imageSize.height + 96, 460), visible.height - 40)
        )

        let state = EditorState()
        if let composed {
            state.textSize = defaultTextSize((composed.width, composed.height))
        }
        self.state = state
        self.session = session

        let canvas = EditorCanvasView(session: session, state: state)
        self.canvas = canvas

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "kacha — 编辑"
        // ARC owns this window; AppKit must not also release it on close.
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentMinSize = NSSize(width: 840, height: 460)
        // The content fills the window and the toolbar sits in the (transparent,
        // title-less) titlebar area, so there is no empty strip above it.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1)

        let root = EditorRootView(
            state: state,
            canvas: canvas,
            onCopy: { [weak self] in self?.copyImage() },
            onSave: { [weak self] in self?.saveImage() },
            onPin: { [weak self] in self?.pinImage() },
            onClose: { [weak self] in self?.close() }
        )
        window.contentView = NSHostingView(rootView: root)

        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
        self.window = window
    }

    // MARK: - Actions

    private func copyImage() {
        guard let data = canvas?.renderExport() else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: .png)
    }

    private func saveImage() {
        guard let data = canvas?.renderExport() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = Self.timestamp() + ".png"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try data.write(to: url)
            } catch {
                let alert = NSAlert()
                alert.messageText = "保存失败"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    private func pinImage() {
        guard let data = canvas?.renderExport() else { return }
        pins.pin(data)
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "kacha-" + formatter.string(from: Date())
    }

    // MARK: - Teardown

    /// Debug: render the editor's current image (the `--smoke-export` path).
    func exportForSmoke() -> Data? {
        canvas?.renderExport()
    }

    func windowWillClose(_ notification: Notification) {
        close()
    }

    func close() {
        window?.orderOut(nil)
        window = nil
        canvas = nil
        state = nil
        session = nil
    }
}
