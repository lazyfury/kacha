// "Pin to screen": floating, always-on-top windows showing an exported image.
//
// A pinned image is a static bitmap, so an `NSImageView` is enough — the pixels
// still come from the editor's PNG.

import AppKit

final class PinWindows {
    private var windows: [NSWindow] = []

    /// Show `png` in a new floating window.
    func pin(_ png: Data) {
        guard let image = NSImage(data: png) else { return }
        var size = image.size
        if size.width <= 0 || size.height <= 0 {
            size = NSSize(width: 320, height: 200)
        }

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        // ARC owns these windows; AppKit must not also release them on close.
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.isOpaque = true
        window.backgroundColor = .black
        window.isMovableByWindowBackground = true
        window.hasShadow = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let imageView = NSImageView(frame: NSRect(origin: .zero, size: size))
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        window.contentView = imageView

        window.setFrameOrigin(nextOrigin(for: size))
        window.makeKeyAndOrderFront(nil)
        windows.append(window)
    }

    /// Close every pinned window.
    func closeAll() {
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
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
