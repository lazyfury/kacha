// "Pin to screen": floating windows showing an exported image.
//
// A pinned image is a static bitmap. The window is borderless and floats above
// other apps, but it is fully interactive: drag anywhere to move it, hover the
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
    private var dragAnchor: NSPoint?
    private var originAnchor: NSPoint?

    private static let closeSize: CGFloat = 20
    private static let closeInset: CGFloat = 8

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

    override func draw(_ dirtyRect: NSRect) {
        image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
        guard hovering, let ctx = NSGraphicsContext.current?.cgContext else { return }
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
        if closeRect.contains(convert(event.locationInWindow, from: nil)) {
            window?.close()
            return
        }
        dragAnchor = NSEvent.mouseLocation
        originAnchor = window?.frame.origin
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragAnchor, let originAnchor, let window else { return }
        let current = NSEvent.mouseLocation
        window.setFrameOrigin(
            NSPoint(
                x: originAnchor.x + (current.x - dragAnchor.x),
                y: originAnchor.y + (current.y - dragAnchor.y)
            )
        )
    }

    override func mouseUp(with event: NSEvent) {
        if event.clickCount == 2 {
            window?.close()
        }
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
        panel.nameFieldStringValue = "ushot-pin.png"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            try? png.write(to: url)
        }
    }

    @objc private func closePin() {
        window?.close()
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
