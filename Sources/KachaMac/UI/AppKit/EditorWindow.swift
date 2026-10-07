// The editor window: a SwiftUI host (Liquid Glass toolbar) over the AppKit
// canvas. Closing it (red button or ⌘W) tears everything down.

import AppKit
import SwiftUI

@MainActor
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
        open(session: session, title: "kacha — 编辑")
    }

    /// Open an empty editor. The tools stay disabled until an image is dropped
    /// in; after that the flow is identical to the capture editor.
    func showViewer() {
        open(session: CaptureSession(), title: "kacha — 看图")
    }

    private func open(session: CaptureSession, title: String) {
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
        state.hasImage = composed != nil
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
        window.title = title
        // ARC owns this window; AppKit must not also release it on close.
        WindowChrome.own(window)
        window.delegate = self
        window.contentMinSize = NSSize(width: 840, height: 460)
        // The content fills the window and the toolbar sits in the (transparent,
        // title-less) titlebar area, so there is no empty strip above it.
        WindowChrome.seamless(window)
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
        Export.copyPNG(data)
    }

    private func saveImage() {
        guard let data = canvas?.renderExport() else { return }
        Export.savePNG(data, suggestedName: Self.timestamp() + ".png")
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

    /// Debug: load an image into the open editor (the `--smoke-viewer` path).
    func loadForSmoke(_ image: CGImage) {
        canvas?.loadImage(image)
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
