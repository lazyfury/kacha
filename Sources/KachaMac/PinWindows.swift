// "Pin to screen": floating windows showing an exported image.
//
// A pinned image is a static bitmap. The window is borderless and floats above
// other apps, but it is fully interactive: drag anywhere to move it, drag a
// corner to resize (aspect-locked, so the image never distorts), hover the
// top-left for a close button, right-click for copy/save/close, double-click or
// Escape to close. Large images are scaled down to fit the screen.

import AppKit
import UniformTypeIdentifiers

/// A borderless floating window that can become key (for Escape) and never
/// releases itself on close (ARC owns it).
final class PinWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

/// The pinned image plus its hover UI and mouse handling.
final class PinView: NSView {
    private let image: NSImage
    private let png: Data
    private var hovering = false

    // Move state.
    private var dragAnchor: NSPoint?
    private var originAnchor: NSPoint?
    // Resize state.
    private var resize: Resize?

    private static let closeSize: CGFloat = 20
    private static let closeInset: CGFloat = 8
    private static let cornerMargin: CGFloat = 14
    private static let minSize = NSSize(width: 80, height: 60)

    /// An in-progress corner resize: the fixed opposite corner, the start
    /// vector from it to the grabbed corner, and the start size.
    private struct Resize {
        let anchor: NSPoint
        let dx: CGFloat
        let dy: CGFloat
        let size: NSSize
    }

    private enum Corner {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    init(image: NSImage, png: Data, frame: NSRect) {
        self.image = image
        self.png = png
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("PinView is created programmatically") }

    /// The pin is shown without becoming key, so the first click must reach it.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var closeRect: CGRect {
        CGRect(
            x: Self.closeInset,
            y: bounds.height - Self.closeInset - Self.closeSize,
            width: Self.closeSize,
            height: Self.closeSize
        )
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
        )
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        let m = Self.cornerMargin
        for rect in [
            CGRect(x: 0, y: bounds.height - m, width: m, height: m),
            CGRect(x: bounds.width - m, y: bounds.height - m, width: m, height: m),
            CGRect(x: 0, y: 0, width: m, height: m),
            CGRect(x: bounds.width - m, y: 0, width: m, height: m),
        ] where rect.width > 0 && rect.height > 0 {
            addCursorRect(rect, cursor: .crosshair)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
        guard hovering, let ctx = NSGraphicsContext.current?.cgContext else { return }
        drawCloseButton(ctx)
        drawResizeGrip(ctx)
    }

    private func drawCloseButton(_ ctx: CGContext) {
        let circle = closeRect
        ctx.setFillColor(NSColor(calibratedWhite: 0, alpha: 0.55).cgColor)
        ctx.fillEllipse(in: circle)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1.6)
        ctx.setLineCap(.round)
        let cross = circle.insetBy(dx: 6, dy: 6)
        ctx.move(to: CGPoint(x: cross.minX, y: cross.minY))
        ctx.addLine(to: CGPoint(x: cross.maxX, y: cross.maxY))
        ctx.move(to: CGPoint(x: cross.maxX, y: cross.minY))
        ctx.addLine(to: CGPoint(x: cross.minX, y: cross.maxY))
        ctx.strokePath()
    }

    /// Three diagonal lines in the bottom-right corner, the classic grip.
    private func drawResizeGrip(_ ctx: CGContext) {
        let inset: CGFloat = 6
        let length: CGFloat = 14
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.85).cgColor)
        ctx.setLineWidth(2)
        ctx.setLineCap(.round)
        let x = bounds.width - inset
        let y = inset
        for step in 0..<3 {
            let offset = CGFloat(step) * 5
            ctx.move(to: CGPoint(x: x - length + offset, y: y))
            ctx.addLine(to: CGPoint(x: x, y: y + length - offset))
        }
        ctx.strokePath()
    }

    // MARK: - Hover

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if closeRect.contains(point) {
            window?.close()
            return
        }
        if let window, let corner = corner(at: NSEvent.mouseLocation, in: window.frame) {
            resize = resizeState(for: corner, frame: window.frame)
            dragAnchor = nil
            originAnchor = nil
            return
        }
        resize = nil
        dragAnchor = NSEvent.mouseLocation
        originAnchor = window?.frame.origin
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let mouse = NSEvent.mouseLocation
        if let resize {
            let dx = mouse.x - resize.anchor.x
            let raw = resize.dx == 0 ? 1 : dx / resize.dx
            let minScale = max(
                Self.minSize.width / resize.size.width,
                Self.minSize.height / resize.size.height
            )
            let scale = max(raw, minScale)
            let corner = CGPoint(
                x: resize.anchor.x + resize.dx * scale,
                y: resize.anchor.y + resize.dy * scale
            )
            window.setFrame(
                NSRect(
                    x: min(resize.anchor.x, corner.x),
                    y: min(resize.anchor.y, corner.y),
                    width: abs(corner.x - resize.anchor.x),
                    height: abs(corner.y - resize.anchor.y)
                ),
                display: true
            )
            return
        }
        guard let dragAnchor, let originAnchor else { return }
        window.setFrameOrigin(
            NSPoint(
                x: originAnchor.x + (mouse.x - dragAnchor.x),
                y: originAnchor.y + (mouse.y - dragAnchor.y)
            )
        )
    }

    override func mouseUp(with event: NSEvent) {
        if resize == nil && event.clickCount == 2 {
            window?.close()
        }
        resize = nil
        dragAnchor = nil
        originAnchor = nil
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {  // Escape
            window?.close()
        } else {
            super.keyDown(with: event)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(item("复制", #selector(copyImage)))
        menu.addItem(item("保存…", #selector(saveImage)))
        menu.addItem(.separator())
        menu.addItem(item("关闭", #selector(closePin)))
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func copyImage() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
    }

    @objc private func saveImage() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "kacha-pin.png"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            try? png.write(to: url)
        }
    }

    @objc private func closePin() {
        window?.close()
    }

    /// Which corner of `frame` (screen coordinates) `point` is near.
    private func corner(at point: CGPoint, in frame: NSRect) -> Corner? {
        let m = Self.cornerMargin
        let left = point.x - frame.minX <= m
        let right = frame.maxX - point.x <= m
        let bottom = point.y - frame.minY <= m
        let top = frame.maxY - point.y <= m
        if left && top { return .topLeft }
        if right && top { return .topRight }
        if left && bottom { return .bottomLeft }
        if right && bottom { return .bottomRight }
        return nil
    }

    private func resizeState(for corner: Corner, frame: NSRect) -> Resize {
        let anchor: CGPoint
        let grab: CGPoint
        switch corner {
        case .topLeft:
            anchor = CGPoint(x: frame.maxX, y: frame.minY)
            grab = CGPoint(x: frame.minX, y: frame.maxY)
        case .topRight:
            anchor = CGPoint(x: frame.minX, y: frame.minY)
            grab = CGPoint(x: frame.maxX, y: frame.maxY)
        case .bottomLeft:
            anchor = CGPoint(x: frame.maxX, y: frame.maxY)
            grab = CGPoint(x: frame.minX, y: frame.minY)
        case .bottomRight:
            anchor = CGPoint(x: frame.minX, y: frame.maxY)
            grab = CGPoint(x: frame.maxX, y: frame.minY)
        }
        return Resize(
            anchor: anchor,
            dx: grab.x - anchor.x,
            dy: grab.y - anchor.y,
            size: frame.size
        )
    }
}

final class PinWindows: NSObject, NSWindowDelegate {
    private var windows: [PinWindow] = []

    /// Show `png` in a new floating window, scaled to fit the screen.
    func pin(_ png: Data) {
        guard let image = NSImage(data: png) else { return }
        var size = image.size
        if size.width <= 0 || size.height <= 0 {
            size = NSSize(width: 320, height: 200)
        }

        let visible = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let scale = min(1, min(visible.width * 0.8 / size.width, visible.height * 0.8 / size.height))
        let windowSize = NSSize(width: size.width * scale, height: size.height * scale)

        let window = PinWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        // ARC owns these windows; AppKit must not also release them on close.
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.delegate = self

        let view = PinView(
            image: image,
            png: png,
            frame: NSRect(origin: .zero, size: windowSize)
        )
        view.autoresizingMask = [.width, .height]
        window.contentView = view

        window.setFrameOrigin(nextOrigin(for: windowSize))
        // Don't steal focus from the app the user pinned over.
        window.orderFrontRegardless()
        windows.append(window)
    }

    /// Close every pinned window.
    func closeAll() {
        for window in windows {
            window.close()
        }
        windows.removeAll()
    }

    var isEmpty: Bool { windows.isEmpty }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        windows.removeAll { $0 === window }
    }

    /// A tidy cascade in the top-right corner of the main screen.
    private func nextOrigin(for size: NSSize) -> NSPoint {
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let offset = CGFloat(windows.count % 8) * 24
        return NSPoint(
            x: visible.maxX - size.width - 24 - offset,
            y: visible.maxY - size.height - 24 - offset
        )
    }
}
