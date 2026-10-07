// The freeze-frame overlay: one borderless panel per display.
//
// The frozen frame is the panel's backing layer contents (a static blit); a
// transparent selection view on top draws the dim mask, selection, handles,
// crosshair and size label, and owns the mouse/keyboard. No per-frame loop: a
// redraw happens only when the selection changes.

import AppKit
import CoreGraphics
import ScreenCaptureKit

/// A borderless panel that can become key so Escape / Return reach the view.
private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// The transparent selection layer drawn over one display's frozen frame.
final class SelectionView: NSView {
    private let display: CapturedDisplay
    private let session: CaptureSession
    weak var controller: OverlayController?

    private var drag: Selection.Drag = .none
    private var pointer: CGPoint?

    private static let dim = NSColor(calibratedWhite: 0, alpha: 0.45).cgColor
    private static let accent = NSColor(calibratedRed: 0.16, green: 0.55, blue: 1, alpha: 1).cgColor
    private static let crosshair = NSColor(calibratedWhite: 1, alpha: 0.55).cgColor

    init(display: CapturedDisplay, session: CaptureSession, controller: OverlayController) {
        self.display = display
        self.session = session
        self.controller = controller
        super.init(frame: NSRect(origin: .zero, size: display.logicalSize))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("SelectionView is created programmatically") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// Local (top-left) point → global logical point.
    private func global(_ local: CGPoint) -> CGPoint {
        CGPoint(x: local.x + display.origin.x, y: local.y + display.origin.y)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let viewport = bounds

        if session.pickMode {
            drawPick(ctx, viewport: viewport)
        } else {
            drawRegion(ctx, viewport: viewport)
        }
    }

    private func drawRegion(_ ctx: CGContext, viewport: CGRect) {
        let local = session.selection.map { Selection.toLocal($0, origin: display.origin) }

        // Dim only once the region is settled: not before the first drag starts,
        // and not while a new region is still being drawn.
        let settled = local != nil && !isNewDrag
        if settled, let local {
            fillMask(ctx, selection: local, viewport: viewport)
        }
        if let local {
            ctx.setStrokeColor(Self.accent)
            ctx.setLineWidth(1)
            ctx.stroke(local)
            ctx.setFillColor(Self.accent)
            for (_, center) in Selection.handleCenters(local) {
                let handle = CGRect(
                    x: center.x - Selection.handleSize / 2,
                    y: center.y - Selection.handleSize / 2,
                    width: Selection.handleSize,
                    height: Selection.handleSize
                )
                if handle.intersects(viewport) {
                    ctx.fill(handle)
                }
            }
            drawLabel(ctx, sizeText(local), near: local, viewport: viewport)
        }
        drawCrosshair(ctx, viewport: viewport)
    }

    private func drawPick(_ ctx: CGContext, viewport: CGRect) {
        // Dim only once a window is under the cursor: the screen stays bright
        // until the user has something selected.
        if let hover = session.hover {
            let local = Selection.toLocal(hover, origin: display.origin)
            fillMask(ctx, selection: local, viewport: viewport)
            if let visible = Selection.intersection(local, viewport) {
                ctx.setStrokeColor(Self.accent)
                ctx.setLineWidth(2)
                ctx.stroke(visible)
            }
            drawLabel(ctx, sizeText(local), near: local, viewport: viewport)
        }
        drawCrosshair(ctx, viewport: viewport)
    }

    private var isNewDrag: Bool {
        if case .new = drag { return true }
        return false
    }

    private func fillMask(_ ctx: CGContext, selection: CGRect, viewport: CGRect) {
        ctx.setFillColor(Self.dim)
        for rect in Selection.maskRects(viewport: viewport, selection: selection)
        where rect.width > 0 && rect.height > 0 {
            ctx.fill(rect)
        }
    }

    private func drawCrosshair(_ ctx: CGContext, viewport: CGRect) {
        guard let p = pointer else { return }
        ctx.setFillColor(Self.crosshair)
        ctx.fill(CGRect(x: p.x, y: 0, width: 1, height: viewport.height))
        ctx.fill(CGRect(x: 0, y: p.y, width: viewport.width, height: 1))
    }

    private func sizeText(_ rect: CGRect) -> String {
        "\(Int(rect.width.rounded())) × \(Int(rect.height.rounded()))"
    }

    private func drawLabel(_ ctx: CGContext, _ text: String, near sel: CGRect, viewport: CGRect) {
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.white,
            ]
        )
        let textSize = attributed.size()
        let padX: CGFloat = 6
        let padY: CGFloat = 3
        let boxW = textSize.width + padX * 2
        let boxH = textSize.height + padY * 2
        let above = sel.minY - boxH - 2 >= viewport.minY
        let y = above ? sel.minY - boxH - 2 : sel.maxY + 2
        let x = max(viewport.minX, min(sel.minX, viewport.maxX - boxW))
        let box = CGRect(x: x, y: y, width: boxW, height: boxH)

        ctx.setFillColor(NSColor(calibratedWhite: 0, alpha: 0.78).cgColor)
        ctx.fill(box)
        attributed.draw(at: CGPoint(x: x + padX, y: y + padY))
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        pointer = local
        if session.pickMode {
            if session.hover != nil {
                session.picked = true
                controller?.pick()
            }
            return
        }
        let (drag, selection) = Selection.begin(current: session.selection, at: global(local))
        self.drag = drag
        session.selection = selection
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        pointer = local
        if session.pickMode {
            controller?.updateHover(at: NSEvent.mouseLocation)
            return
        }
        session.selection = Selection.update(drag, to: global(local), current: session.selection)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if session.pickMode { return }
        session.selection = Selection.finish(drag, current: session.selection)
        drag = .none
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        pointer = convert(event.locationInWindow, from: nil)
        if session.pickMode {
            controller?.updateHover(at: NSEvent.mouseLocation)
        }
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        pointer = nil
        needsDisplay = true
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:  // Escape
            controller?.cancel()
        case 36, 76:  // Return / keypad Enter
            controller?.confirm()
        case 123, 124, 125, 126:  // arrows
            guard let sel = session.selection else { return }
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            let delta: CGPoint
            switch event.keyCode {
            case 123: delta = CGPoint(x: -step, y: 0)
            case 124: delta = CGPoint(x: step, y: 0)
            case 125: delta = CGPoint(x: 0, y: step)
            default: delta = CGPoint(x: 0, y: -step)
            }
            session.selection = sel.offsetBy(dx: delta.x, dy: delta.y)
            needsDisplay = true
        default:
            super.keyDown(with: event)
        }
    }
}

/// Owns the overlay panels and the shared session for one capture.
final class OverlayController {
    private var panels: [(window: NSWindow, view: SelectionView)] = []
    private var windowsByID: [CGWindowID: SCWindow] = [:]

    private(set) var session: CaptureSession?
    private(set) var hoveredWindow: SCWindow?

    var isOpen: Bool { !panels.isEmpty }
    var isPicking: Bool { session?.pickMode ?? false }

    var onConfirm: ((CaptureSession) -> Void)?
    var onCancel: ((CaptureSession) -> Void)?
    var onPick: ((CaptureSession, SCWindow) -> Void)?

    /// Open one panel per display, over `session`'s frozen frames.
    func show(session: CaptureSession, windows: [SCWindow], pick: Bool) {
        close()
        self.session = session
        session.pickMode = pick
        self.windowsByID = Dictionary(
            windows.map { ($0.windowID, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        for display in session.displayList {
            guard let screen = Self.screen(for: display.displayID) else { continue }
            let panel = OverlayPanel(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.isReleasedWhenClosed = false
            panel.animationBehavior = .none
            panel.isOpaque = true
            panel.backgroundColor = .black
            panel.hasShadow = false
            panel.isMovable = false
            panel.acceptsMouseMovedEvents = true
            // Never let a future capture include our own overlay.
            panel.sharingType = .none

            let container = NSView(frame: NSRect(origin: .zero, size: display.logicalSize))
            container.wantsLayer = true
            container.layer?.contents = display.image
            container.layer?.contentsGravity = .resize
            container.layer?.contentsScale = display.scale
            container.layer?.backgroundColor = NSColor.black.cgColor

            let view = SelectionView(display: display, session: session, controller: self)
            view.autoresizingMask = [.width, .height]
            container.addSubview(view)

            panel.contentView = container
            panel.setFrame(screen.frame, display: false)
            panel.orderFrontRegardless()
            panels.append((panel, view))
        }

        // Make one panel key so Escape / Return reach a SelectionView (the
        // selection is shared, so which panel it is does not matter).
        if let first = panels.first {
            first.window.makeKey()
            first.window.makeFirstResponder(first.view)
        }
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Redraw every panel (used after the shared hover changed).
    func refresh() {
        for panel in panels {
            panel.view.needsDisplay = true
        }
    }

    /// Hit-test the window under `point` (AppKit screen coordinates) with
    /// AppKit's own API — the authoritative z-order/occlusion test.
    func updateHover(at point: CGPoint) {
        let window = windowUnder(point)
        hoveredWindow = window
        if let frame = window?.frame {
            session?.hover = frame
        } else {
            session?.hover = nil
        }
        refresh()
    }

    func pick() {
        guard let session, let window = hoveredWindow else { return }
        dismiss()
        onPick?(session, window)
    }

    func confirm() {
        guard let session else { return }
        session.confirm()
        dismiss()
        onConfirm?(session)
    }

    func cancel() {
        guard let session else { return }
        dismiss()
        onCancel?(session)
    }

    /// Close the panels but keep the session alive (the editor picks it up).
    func dismiss() {
        for panel in panels {
            panel.window.orderOut(nil)
        }
        panels.removeAll()
        windowsByID = [:]
        hoveredWindow = nil
    }

    /// Tear the overlays down and drop the session.
    func close() {
        dismiss()
        session = nil
    }

    /// The window under `point`, ignoring our own panels.
    private func windowUnder(_ point: CGPoint) -> SCWindow? {
        var reference = panels.first { $0.window.frame.contains(point) }?.window.windowNumber ?? 0
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

    /// The `NSScreen` backing a CoreGraphics display id.
    private static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { screen in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
            return (number as? NSNumber)?.uint32Value == displayID
        }
    }
}
