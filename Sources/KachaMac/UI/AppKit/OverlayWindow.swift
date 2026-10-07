// The freeze-frame overlay: one borderless panel per display.
//
// The frozen frame is the panel's backing layer contents (a static blit); a
// transparent surface view on top draws the dim mask / selection / handles /
// crosshair / magnifier and owns the mouse/keyboard. There is no per-frame loop:
// a redraw happens only when the selection or pointer changes.
//
// The capture flow and the colour picker are separate subclasses of a small
// shared `OverlaySurfaceView`, so each mode carries only its own interaction.

import AppKit
import CoreGraphics
import ScreenCaptureKit

/// A borderless panel that can become key so Escape / Return reach the view.
private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Shared behaviour of an overlay surface: pointer tracking, coordinate
/// conversion, the crosshair and the colour lookup under the cursor.
class OverlaySurfaceView: NSView {
    let display: CapturedDisplay
    let session: CaptureSession
    weak var controller: OverlayController?

    /// The pointer in this view's local (top-left) coordinates, if inside.
    var pointer: CGPoint?

    init(display: CapturedDisplay, session: CaptureSession, controller: OverlayController) {
        self.display = display
        self.session = session
        self.controller = controller
        super.init(frame: NSRect(origin: .zero, size: display.logicalSize))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("OverlaySurfaceView is created programmatically") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
        )
    }

    /// Local (top-left) point → global logical point.
    func global(_ local: CGPoint) -> CGPoint {
        CGPoint(x: local.x + display.origin.x, y: local.y + display.origin.y)
    }

    /// The colour of the frozen frame under a local point, if in bounds.
    func color(at local: CGPoint) -> NSColor? {
        ColorPicker.pixel(
            display.image,
            x: Int(local.x * display.scale),
            y: Int(local.y * display.scale)
        )
    }

    func drawCrosshair(_ ctx: CGContext, viewport: CGRect) {
        guard let p = pointer else { return }
        ctx.setFillColor(Self.crosshair)
        ctx.fill(CGRect(x: p.x, y: 0, width: 1, height: viewport.height))
        ctx.fill(CGRect(x: 0, y: p.y, width: viewport.width, height: 1))
    }

    override func mouseExited(with event: NSEvent) {
        pointer = nil
        needsDisplay = true
    }

    private static let crosshair = NSColor(calibratedWhite: 1, alpha: 0.55).cgColor
}

/// Region / window / full-screen picking: a settled selection wins; otherwise
/// the window under the cursor is highlighted, and a click captures it (a click
/// on the desktop captures the whole display).
final class CaptureSelectionView: OverlaySurfaceView {
    private var drag: Selection.Drag = .none
    /// The pointer-down point (global logical), for click-vs-drag.
    private var anchor: CGPoint = .zero
    /// Set once the pointer moved past `clickSlop` since mouse-down.
    private var didDrag = false
    /// Whether a settled selection existed when the current press started — a
    /// click outside it just clears it instead of capturing.
    private var hadSelection = false

    /// A pointer that moved less than this (logical points) is a click, not a
    /// drag — the click-vs-region discrimination.
    private static let clickSlop: CGFloat = 4

    private static let dim = NSColor(calibratedWhite: 0, alpha: 0.45).cgColor
    private static let accent = NSColor(calibratedRed: 0.16, green: 0.55, blue: 1, alpha: 1).cgColor

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let viewport = bounds
        let local = session.selection.map { Selection.toLocal($0, origin: display.origin) }
        let settled = local != nil && !isNewDrag

        if settled, let local {
            fillMask(ctx, selection: local, viewport: viewport)
            drawSelection(ctx, local, viewport: viewport)
        } else if !isNewDrag, let hover = session.hover {
            let hoverLocal = Selection.toLocal(hover, origin: display.origin)
            fillMask(ctx, selection: hoverLocal, viewport: viewport)
            ctx.setStrokeColor(Self.accent)
            ctx.setLineWidth(2)
            ctx.stroke(Selection.intersection(hoverLocal, viewport) ?? hoverLocal)
            drawLabel(ctx, sizeText(hoverLocal), near: hoverLocal, viewport: viewport)
        } else if let local {
            // A new region is being drawn: keep the screen bright, just outline.
            drawSelection(ctx, local, viewport: viewport)
        }
        drawCrosshair(ctx, viewport: viewport)
        drawHint(ctx, viewport: viewport, hasSelection: session.selection != nil)
        if settled, let local, bounds.contains(CGPoint(x: local.midX, y: local.midY)) {
            drawActions(ctx, selection: local, viewport: viewport)
        }
    }

    /// The selection border, handles and size label.
    private func drawSelection(_ ctx: CGContext, _ local: CGRect, viewport: CGRect) {
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

    /// The bottom-centre instruction pill. The text reflects the current step so
    /// the two-level back (clear selection, then cancel) is explicit.
    private func drawHint(_ ctx: CGContext, viewport: CGRect, hasSelection: Bool) {
        let text = hasSelection
            ? "Enter 完成 · 点空白 / 右键 / Esc 取消选区"
            : "拖拽框选 · 点击窗口截窗口 · 点击空白处截整屏 · Esc 退出"
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.white,
            ]
        )
        let size = attributed.size()
        let padX: CGFloat = 12
        let padY: CGFloat = 6
        let boxW = size.width + padX * 2
        let boxH = size.height + padY * 2
        let box = CGRect(
            x: viewport.midX - boxW / 2,
            y: viewport.maxY - boxH - 24,
            width: boxW,
            height: boxH
        )
        ctx.setFillColor(NSColor(calibratedWhite: 0, alpha: 0.6).cgColor)
        ctx.addPath(
            CGPath(
                roundedRect: box,
                cornerWidth: boxH / 2,
                cornerHeight: boxH / 2,
                transform: nil
            )
        )
        ctx.fillPath()
        attributed.draw(at: CGPoint(x: box.minX + padX, y: box.minY + padY))
    }

    private func sizeText(_ rect: CGRect) -> String {
        "\(Int(rect.width.rounded())) × \(Int(rect.height.rounded()))"
    }

    // MARK: - Quick actions

    /// A one-click action shown next to a settled selection.
    private enum QuickAction {
        case cancel
        case save
        case confirm
    }

    private struct QuickButton {
        let title: String
        let action: QuickAction
        let primary: Bool
    }

    private static let quickButtons: [QuickButton] = [
        QuickButton(title: "取消", action: .cancel, primary: false),
        QuickButton(title: "直接保存", action: .save, primary: false),
        QuickButton(title: "去编辑", action: .confirm, primary: true),
    ]

    /// The action bar's rect and each button's frame, in local coordinates.
    /// Anchored just below the selection (or above / at the bottom edge when
    /// there is no room), clamped to the display.
    private func actionLayout(
        selection: CGRect,
        viewport: CGRect
    ) -> (bar: CGRect, buttons: [(QuickAction, CGRect)])? {
        guard Selection.intersection(selection, viewport) != nil else { return nil }

        let buttonHeight: CGFloat = 28
        let hPadding: CGFloat = 14
        let spacing: CGFloat = 8
        let padding: CGFloat = 6
        let margin: CGFloat = 8
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)

        let widths = Self.quickButtons.map { button -> CGFloat in
            let text = NSAttributedString(string: button.title, attributes: [.font: font])
            return max(text.size().width + hPadding * 2, 54)
        }
        let contentWidth = widths.reduce(0, +)
            + spacing * CGFloat(Self.quickButtons.count - 1)
        let barWidth = contentWidth + padding * 2
        let barHeight = buttonHeight + padding * 2

        var x = selection.midX - barWidth / 2
        x = min(max(x, viewport.minX + margin), viewport.maxX - barWidth - margin)
        var y = selection.maxY + margin
        if y + barHeight > viewport.maxY - margin {
            y = selection.minY - barHeight - margin
        }
        if y < viewport.minY + margin {
            y = viewport.maxY - barHeight - margin
        }

        let bar = CGRect(x: x, y: y, width: barWidth, height: barHeight)
        var buttons: [(QuickAction, CGRect)] = []
        var cursor = bar.minX + padding
        for (index, button) in Self.quickButtons.enumerated() {
            let frame = CGRect(
                x: cursor,
                y: bar.minY + padding,
                width: widths[index],
                height: buttonHeight
            )
            buttons.append((button.action, frame))
            cursor += widths[index] + spacing
        }
        return (bar, buttons)
    }

    private func drawActions(_ ctx: CGContext, selection: CGRect, viewport: CGRect) {
        guard let layout = actionLayout(selection: selection, viewport: viewport) else { return }
        ctx.setFillColor(NSColor(calibratedWhite: 0.08, alpha: 0.92).cgColor)
        ctx.addPath(
            CGPath(roundedRect: layout.bar, cornerWidth: 10, cornerHeight: 10, transform: nil)
        )
        ctx.fillPath()

        for (index, entry) in layout.buttons.enumerated() {
            let (_, frame) = entry
            let button = Self.quickButtons[index]
            ctx.setFillColor(
                button.primary ? Self.accent : NSColor(calibratedWhite: 1, alpha: 0.16).cgColor
            )
            ctx.addPath(
                CGPath(roundedRect: frame, cornerWidth: 7, cornerHeight: 7, transform: nil)
            )
            ctx.fillPath()

            let attributed = NSAttributedString(
                string: button.title,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                    .foregroundColor: NSColor.white,
                ]
            )
            let size = attributed.size()
            attributed.draw(
                at: CGPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2)
            )
        }
    }

    /// Run a quick action from the bar.
    private func perform(_ action: QuickAction) {
        switch action {
        case .cancel: controller?.cancel()
        case .save: controller?.save()
        case .confirm: controller?.confirm()
        }
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
        // A click on the quick-action bar wins over starting a new drag.
        if let selection = session.selection {
            let localSelection = Selection.toLocal(selection, origin: display.origin)
            if bounds.contains(CGPoint(x: localSelection.midX, y: localSelection.midY)),
                let layout = actionLayout(selection: localSelection, viewport: bounds)
            {
                for (index, entry) in layout.buttons.enumerated() where entry.1.contains(local) {
                    perform(Self.quickButtons[index].action)
                    return
                }
            }
        }
        let point = global(local)
        anchor = point
        didDrag = false
        hadSelection = session.selection != nil
        let (drag, selection) = Selection.begin(current: session.selection, at: point)
        self.drag = drag
        session.selection = selection
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        pointer = local
        let point = global(local)
        if !didDrag {
            let dx = point.x - anchor.x
            let dy = point.y - anchor.y
            if (dx * dx + dy * dy).squareRoot() >= Self.clickSlop {
                didDrag = true
            }
        }
        session.selection = Selection.update(drag, to: point, current: session.selection)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let wasNew: Bool
        if case .new = drag { wasNew = true } else { wasNew = false }
        let usable = session.selection.map { Selection.usable($0) } ?? false

        if wasNew && (!didDrag || !usable) {
            // A click. Outside a settled selection it only drops that selection
            // (so a stray click cannot capture and lose the region); with no
            // selection it acts on whatever is under the cursor: a window
            // (capture it) or the desktop (capture the screen).
            let hadSelection = self.hadSelection
            session.selection = nil
            drag = .none
            didDrag = false
            self.hadSelection = false
            if hadSelection {
                controller?.refresh()
            } else {
                controller?.click(at: NSEvent.mouseLocation, display: display)
            }
            return
        }
        session.selection = Selection.finish(drag, current: session.selection)
        drag = .none
        didDrag = false
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        pointer = convert(event.locationInWindow, from: nil)
        controller?.updateHover(at: NSEvent.mouseLocation)
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        back()
    }

    /// Back one step: drop a settled selection and return to window / full-screen
    /// picking; with no selection, cancel the whole capture.
    private func back() {
        if session.selection != nil {
            session.selection = nil
            drag = .none
            didDrag = false
            needsDisplay = true
        } else {
            controller?.cancel()
        }
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:  // Escape
            back()
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

/// The colour-picker overlay: crosshair + magnifier + hex readout. A click or
/// Return copies the sampled colour's hex and closes.
final class ColorPickView: OverlaySurfaceView {
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        drawCrosshair(ctx, viewport: bounds)
        guard let p = pointer, let color = color(at: p) else { return }
        ColorPicker.drawMagnifier(
            ctx,
            image: display.image,
            at: p,
            imageX: Int(p.x * display.scale),
            imageY: Int(p.y * display.scale),
            color: color,
            viewport: bounds
        )
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        pointer = local
        if let color = color(at: local) {
            controller?.finishColorPick(color)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        pointer = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        pointer = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:  // Escape
            controller?.cancel()
        case 36, 76:  // Return / keypad Enter: pick at the cursor
            if let p = pointer, let color = color(at: p) {
                controller?.finishColorPick(color)
            }
        default:
            super.keyDown(with: event)
        }
    }
}

/// Owns the overlay panels and the shared session for one capture.
@MainActor
final class OverlayController {
    private var panels: [(window: NSWindow, view: OverlaySurfaceView)] = []
    private var windowsByID: [CGWindowID: SCWindow] = [:]

    /// Bounded walk down the window stack: the list can contain windows we do
    /// not know (other apps' panels), and this caps the walk if none are ours.
    private static let maxWindowStackWalk = 12

    private(set) var session: CaptureSession?
    private(set) var hoveredWindow: SCWindow?

    var isOpen: Bool { !panels.isEmpty }

    var onConfirm: ((CaptureSession) -> Void)?
    var onCancel: ((CaptureSession) -> Void)?
    var onSave: ((CaptureSession) -> Void)?
    var onPick: ((CaptureSession, SCWindow) -> Void)?

    /// Open one panel per display, over `session`'s frozen frames.
    func show(session: CaptureSession, windows: [SCWindow]) {
        close()
        self.session = session
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
            WindowChrome.own(panel)
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

            let view: OverlaySurfaceView = session.mode == .colorPicker
                ? ColorPickView(display: display, session: session, controller: self)
                : CaptureSelectionView(display: display, session: session, controller: self)
            view.autoresizingMask = [.width, .height]
            container.addSubview(view)

            panel.contentView = container
            panel.setFrame(screen.frame, display: false)
            panel.orderFrontRegardless()
            panels.append((panel, view))
        }

        // Make one panel key so Escape / Return reach a surface view (the
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

    /// Copy the picked colour's hex and close.
    func finishColorPick(_ color: NSColor) {
        Export.copyString(color.hexString)
        dismiss()
    }

    /// A click: a window under the cursor is captured, otherwise the whole
    /// display the click landed on.
    func click(at point: CGPoint, display: CapturedDisplay) {
        if let window = windowUnder(point) {
            pick(window)
        } else {
            captureFullScreen(display)
        }
    }

    func pick(_ window: SCWindow) {
        guard let session else { return }
        hoveredWindow = window
        dismiss()
        onPick?(session, window)
    }

    /// Capture the whole display from its frozen frame.
    func captureFullScreen(_ display: CapturedDisplay) {
        guard let session else { return }
        session.composed = Compose.composed(from: display.image)
        dismiss()
        onConfirm?(session)
    }

    func confirm() {
        guard let session else { return }
        session.confirm()
        dismiss()
        onConfirm?(session)
    }

    /// Confirm the selection and save it without opening the editor.
    func save() {
        guard let session else { return }
        session.confirm()
        dismiss()
        onSave?(session)
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
        for _ in 0..<Self.maxWindowStackWalk {
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
