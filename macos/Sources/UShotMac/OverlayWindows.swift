// The freeze-frame overlay: one borderless panel per display, each rendering
// its captured frame through its own Rust (`OverlayApp`) instance.
//
// The windows are Swift's; the pixels and the UI are Rust's. `overlays.queue`
// shows every display at once (the design's "multi-display" case), and `close`
// tears them down and drops the session.

import AppKit
import ScreenCaptureKit
import UShotNative

final class OverlayWindows {
    private final class Entry {
        let window: NSWindow
        let view: HostView
        let app: OpaquePointer

        init(window: NSWindow, view: HostView, app: OpaquePointer) {
            self.window = window
            self.view = view
            self.app = app
        }
    }

    private var entries: [Entry] = []
    private(set) var session: UInt64 = 0
    /// The pickable windows by CG window id (kept for occlusion-safe capture).
    private var windowsByID: [CGWindowID: SCWindow] = [:]
    /// The window currently under the cursor (tracked for capture).
    private(set) var hoveredWindow: SCWindow?
    /// Whether the current overlay is in window-pick mode.
    private(set) var isPicking = false

    /// Whether any overlay panel is on screen.
    var isOpen: Bool { !entries.isEmpty }

    /// Freeze the displays: create the session, hand Rust every frame and the
    /// window rectangles, then open one panel per display.
    ///
    /// Must run on the main thread — the session registry in Rust is
    /// thread-local.
    func show(displays: [CapturedDisplay], windows: [SCWindow], pick: Bool) {
        close()
        let session = ushot_session_new()
        self.session = session
        self.isPicking = pick
        self.windowsByID = Dictionary(
            windows.map { ($0.windowID, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // Inject the frames *before* opening the windows, so each `OverlayApp`
        // has its image when its `init` runs.
        for display in displays {
            display.rgba.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                ushot_display_image(
                    session,
                    display.displayID,
                    display.originX,
                    display.originY,
                    display.logicalWidth,
                    display.logicalHeight,
                    display.scale,
                    base,
                    buffer.count
                )
            }
        }

        ushot_session_set_pick_window(session, pick)

        for display in displays {
            guard let screen = Self.screen(for: display.displayID) else { continue }
            let frame = screen.frame

            let window = NSWindow(
                contentRect: frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            // ARC owns these panels; AppKit must not also release them on close.
            window.isReleasedWhenClosed = false
            // A borderless panel has no title bar to zoom from; the default
            // entrance animation is what reads as a "zoom" flash on first show.
            window.animationBehavior = .none
            window.isOpaque = true
            window.backgroundColor = .black
            window.hasShadow = false
            window.isMovable = false
            window.acceptsMouseMovedEvents = true
            // Never let a future capture include our own overlay.
            window.sharingType = .none

            let view = HostView(frame: NSRect(origin: .zero, size: frame.size))
            // The overlay has no title bar; every click is app input.
            view.interceptsTitlebar = false
            window.contentView = view
            window.setFrame(frame, display: false)
            // Resolve the backing scale *before* reading `pixelSize`: the view was
            // created outside a window, so its first geometry pass used 1x.
            // Starting Rust on that stale 1x size and only reconfiguring later
            // leaves the first presented frame mismatched with the drawable —
            // the freeze-frame "zoom" flash.
            window.layoutIfNeeded()

            // Start Rust and present the first frame **while the panel is still
            // off-screen**. Ordering it front first would composite its opaque
            // backing for one frame — the screen flash.
            let (width, height) = view.pixelSize
            guard
                let app = ushot_host_start(
                    Unmanaged.passUnretained(view.metalLayer).toOpaque(),
                    width,
                    height,
                    view.scaleFactor,
                    UInt32(USHOT_ROLE_OVERLAY),
                    session,
                    display.displayID
                )
            else {
                window.orderOut(nil)
                continue
            }
            view.app = app
            // Follow later drawable / backing changes (a display change, or the
            // window server moving the panel) so the surface never falls out of
            // sync with the layer.
            view.onGeometryChange = { [weak view] width, height, scale in
                guard let app = view?.app else { return }
                ushot_host_resize(app, width, height, scale)
            }
            ushot_host_frame(app)
            view.syncFrameState()
            entries.append(Entry(window: window, view: view, app: app))
        }

        // Order every panel front only after all of them have presented, so
        // several displays darken in the same composite instead of one by one.
        for entry in entries {
            entry.window.orderFrontRegardless()
        }

        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Run one frame on every panel.
    func frameAll() {
        for entry in entries {
            ushot_host_frame(entry.app)
            entry.view.syncFrameState()
        }
    }

    /// Whether any panel wants another frame.
    func needsFrame() -> Bool {
        entries.contains { ushot_host_needs_frame($0.app) }
    }

    /// Hit-test the window under `point` (AppKit screen coordinates) with
    /// AppKit's own API — the authoritative z-order/occlusion test, which
    /// `SCWindow` does not expose.
    ///
    /// Returns nil for our own windows (they are not in `windowsByID`) and when
    /// there is none.
    func windowUnder(_ point: NSPoint) -> SCWindow? {
        // Look below the overlay panel on the display containing the point: our
        // panels sit above everything, so passing one ignores all of them. Then
        // keep walking down past windows we do not consider pickable (our own
        // editor/pinned windows, or anything SCK did not list) until a real app
        // window shows up.
        var reference = entries.first { $0.window.frame.contains(point) }?.window.windowNumber
            ?? 0
        for _ in 0..<12 {
            let number = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: reference)
            if number == 0 {
                return nil
            }
            if let window = windowsByID[CGWindowID(number)] {
                return window
            }
            reference = number
        }
        return nil
    }

    /// Track the hovered window and push its rect (global logical points) to
    /// Rust, so the overlay draws exactly the window the shell will capture.
    func updateHover(at point: NSPoint, session: UInt64) {
        let window = windowUnder(point)
        hoveredWindow = window
        if let frame = window?.frame {
            ushot_session_set_hover(
                session,
                true,
                Float(frame.minX),
                Float(frame.minY),
                Float(frame.width),
                Float(frame.height)
            )
        } else {
            ushot_session_set_hover(session, false, 0, 0, 0, 0)
        }
    }

    /// Close the panels but keep the session alive (the editor picks it up).
    func dismiss() {
        // Destroy the Rust app while the window (and its CAMetalLayer) is still
        // alive — the wgpu surface borrows the layer. Clear the view's handle
        // first: ordering the window out can deliver events synchronously.
        for entry in entries {
            // Stop forwarding geometry/input before the Rust app is freed.
            entry.view.onGeometryChange = nil
            entry.view.app = nil
            ushot_host_destroy(entry.app)
            entry.window.orderOut(nil)
        }
        entries.removeAll()
        windowsByID = [:]
        hoveredWindow = nil
        isPicking = false
    }

    /// Tear the overlays down and drop the session.
    func close() {
        dismiss()
        if session != 0 {
            ushot_session_drop(session)
            session = 0
        }
    }

    /// The `NSScreen` backing a CoreGraphics display id.
    private static func screen(for displayID: UInt32) -> NSScreen? {
        NSScreen.screens.first { screen in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
            return (number as? NSNumber)?.uint32Value == displayID
        }
    }
}
