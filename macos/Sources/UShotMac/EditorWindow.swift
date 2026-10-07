// The editor window: a normal titled window whose `HostView` runs the Rust
// `EditorApp` over the session's composed image.
//
// `show(session:)` takes ownership of the session; closing the window (red
// button or ⌘W) destroys the Rust app and drops the session.

import AppKit
import UShotNative

final class EditorWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var view: HostView?
    private var app: OpaquePointer?
    private var session: UInt64 = 0

    /// Whether the editor window is on screen.
    var isOpen: Bool { window != nil }

    /// Open an editor for `session` (the composed image lives in Rust).
    func show(session: UInt64) {
        close()

        var imageWidth: UInt32 = 900
        var imageHeight: UInt32 = 600
        _ = ushot_session_composed_size(session, &imageWidth, &imageHeight)
        let visible = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let contentSize = NSSize(
            width: min(max(CGFloat(imageWidth) + 32, 640), visible.width - 40),
            height: min(max(CGFloat(imageHeight) + 96, 460), visible.height - 40)
        )

        let view = HostView(frame: NSRect(origin: .zero, size: contentSize))
        // A real title bar handles dragging; the toolbar is at the very top of
        // the content, so nothing may be swallowed there.
        view.interceptsTitlebar = false
        self.view = view

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ushot — 编辑"
        // ARC owns this window; AppKit must not also release it on close (that
        // double release is an `objc_release` crash when the red button is used).
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        // Resolve the backing scale before `pixelSize` (the view was built
        // outside a window and its first geometry pass used 1x).
        window.layoutIfNeeded()
        self.window = window
        self.session = session

        let (pixelWidth, pixelHeight) = view.pixelSize
        guard
            let app = ushot_host_start(
                Unmanaged.passUnretained(view.metalLayer).toOpaque(),
                pixelWidth,
                pixelHeight,
                view.scaleFactor,
                UInt32(USHOT_ROLE_EDITOR),
                session,
                0
            )
        else {
            window.orderOut(nil)
            self.window = nil
            self.view = nil
            ushot_session_drop(session)
            self.session = 0
            return
        }
        self.app = app
        view.app = app
        // Reconfigure the surface whenever the drawable changes (live resize,
        // backing change) instead of polling once a frame.
        view.onGeometryChange = { [weak view] width, height, scale in
            guard let app = view?.app else { return }
            ushot_host_resize(app, width, height, scale)
        }
    }

    /// Run one frame.
    func frameAll() {
        guard let app, let view else { return }
        ushot_host_frame(app)
        view.syncFrameState()
    }

    /// Whether the editor wants another frame.
    func needsFrame() -> Bool {
        app.map { ushot_host_needs_frame($0) } ?? false
    }

    /// Park an action (copy/save/pin/close) as a toolbar button would.
    func requestAction(_ action: UInt32) {
        if let app {
            ushot_host_request_action(app, action)
        }
    }

    /// The editor's pending action (0 none, 1 copy, 2 save, 3 pin, 4 close).
    func takeAction() -> UInt32 {
        app.map { ushot_host_take_action($0) } ?? 0
    }

    /// The PNG for the pending action, or nil.
    func actionPNG() -> Data? {
        guard let app else { return nil }
        let length = ushot_host_action_png(app, nil, 0)
        guard length > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: length)
        let copied = bytes.withUnsafeMutableBufferPointer { buffer in
            ushot_host_action_png(app, buffer.baseAddress, length)
        }
        return copied == length ? Data(bytes) : nil
    }

    /// Release the pending action's PNG.
    func actionDone() {
        if let app {
            ushot_host_action_done(app)
        }
    }

    func windowWillClose(_ notification: Notification) {
        close()
    }

    /// Debug: close through AppKit's own path (the red button / ⌘W), so the
    /// `windowWillClose` teardown is exercised.
    func smokeClose() {
        window?.performClose(nil)
    }

    /// Tear the editor down and drop the session.
    func close() {
        // Stop the view forwarding input *before* the Rust app is freed: ordering
        // the window out can synchronously deliver events (mouseExited, resign
        // key) that would otherwise reach the freed pointer.
        view?.app = nil
        view?.onGeometryChange = nil
        if let app {
            ushot_host_destroy(app)
            self.app = nil
        }
        window?.orderOut(nil)
        window = nil
        view = nil
        if session != 0 {
            ushot_session_drop(session)
            session = 0
        }
    }
}
