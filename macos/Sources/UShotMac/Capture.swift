// ScreenCaptureKit: freeze every display into an RGBA8 frame for Rust.
//
// Swift owns the platform capture (exactly as it owns the window); Rust only
// receives pixels and uploads them as a texture. The freeze-frame look comes
// from capturing *before* the overlay windows appear, then drawing the frozen
// image as the overlay's background.

import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// The frozen displays plus the pickable windows for window-pick mode.
struct CaptureResult {
    let displays: [CapturedDisplay]
    let windows: [SCWindow]
}

/// One display's frozen frame, ready to hand to `ushot_display_image`.
struct CapturedDisplay {
    let displayID: UInt32
    /// The display's top-left in global logical points (CG coords, origin top-left).
    let originX: Float
    let originY: Float
    let logicalWidth: UInt32
    let logicalHeight: UInt32
    /// Backing scale (2.0 on Retina).
    let scale: Double
    /// Tightly packed RGBA8, row-major, straight alpha.
    let rgba: [UInt8]
}

/// A captured window's pixels (its own content, occlusion-independent).
struct CapturedWindow {
    let width: Int
    let height: Int
    let bytes: [UInt8]
}

/// Capture failures worth telling the user about.
enum CaptureError: Error, LocalizedError {
    case noDisplays
    case encodeFailed

    var errorDescription: String? {
        switch self {
        case .noDisplays:
            return "没有找到可截图的显示器。"
        case .encodeFailed:
            return "无法把捕获的画面转换为 RGBA。"
        }
    }
}

enum Capture {
    /// Freeze every display, excluding this app's own windows so the overlay is
    /// never captured into itself. Also returns the on-screen window rectangles
    /// (global logical points) for window-pick mode.
    static func frozenDisplays() async throws -> CaptureResult {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownWindows = content.windows.filter { $0.owningApplication?.processID == ownPID }

        // Capture every display at once: the ScreenCaptureKit round-trip is the
        // slow part, and a multi-display setup otherwise pays it serially. The
        // results are re-assembled in display order.
        let displays = content.displays
        let captured = try await withThrowingTaskGroup(of: (Int, CapturedDisplay).self) { group in
            for (index, display) in displays.enumerated() {
                group.addTask {
                    let captured = try await Self.capture(display: display, excluding: ownWindows)
                    return (index, captured)
                }
            }
            var results = [CapturedDisplay?](repeating: nil, count: displays.count)
            for try await (index, display) in group {
                results[index] = display
            }
            return results.compactMap { $0 }
        }
        if captured.isEmpty {
            throw CaptureError.noDisplays
        }

        // The pickable windows, in **front-to-back z-order**, from
        // CoreGraphics: ScreenCaptureKit's `SCWindow` has no ordering, so its
        // list would highlight an occluded window behind the cursor. Filter to
        // normal-layer, on-screen, opaque-enough windows that are not ours.
        let order = Self.onScreenWindowOrder(excluding: ownPID)
        var byID: [CGWindowID: SCWindow] = [:]
        for window in content.windows where byID[window.windowID] == nil {
            byID[window.windowID] = window
        }
        let windows = order.compactMap { byID[$0] }

        return CaptureResult(displays: captured, windows: windows)
    }

    /// Capture one display at its native pixel resolution, excluding our own
    /// windows so the overlay is never captured into itself.
    private static func capture(
        display: SCDisplay,
        excluding windows: [SCWindow]
    ) async throws -> CapturedDisplay {
        let filter = SCContentFilter(display: display, excludingWindows: windows)
        let frame = display.frame
        // `SCDisplay.width`/`height`/`frame` are all in POINTS; capture at
        // native pixels or the crop is 1x (soft on Retina).
        let scale = Self.backingScale(for: display.displayID)
        let config = SCStreamConfiguration()
        config.width = max(Int((frame.width * scale).rounded()), 1)
        config.height = max(Int((frame.height * scale).rounded()), 1)
        config.showsCursor = true
        config.capturesAudio = false

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )
        guard let rgba = rgbaBytes(from: image) else {
            throw CaptureError.encodeFailed
        }
        return CapturedDisplay(
            displayID: display.displayID,
            originX: Float(frame.origin.x),
            originY: Float(frame.origin.y),
            logicalWidth: UInt32(frame.width.rounded()),
            logicalHeight: UInt32(frame.height.rounded()),
            scale: Double(scale),
            rgba: rgba
        )
    }

    /// The on-screen window ids, front-to-back (topmost first), excluding
    /// `pid`. Uses `CGWindowListCopyWindowInfo`, which is the only public source
    /// of the window stacking order.
    private static func onScreenWindowOrder(excluding pid: pid_t) -> [CGWindowID] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard
            let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
                as? [[String: Any]]
        else {
            return []
        }
        var order: [CGWindowID] = []
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else {
                continue
            }
            guard let alpha = info[kCGWindowAlpha as String] as? Double, alpha > 0.01 else {
                continue
            }
            guard let owner = info[kCGWindowOwnerPID as String] as? pid_t, owner != pid else {
                continue
            }
            guard let number = info[kCGWindowNumber as String] as? CGWindowID else {
                continue
            }
            if let bounds = info[kCGWindowBounds as String] as? [String: Any],
                let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                rect.width >= 48,
                rect.height >= 48
            {
                order.append(number)
            }
        }
        return order
    }

    /// The backing scale of the display with `displayID` (2.0 on Retina).
    private static func backingScale(for displayID: CGDirectDisplayID) -> CGFloat {
        for screen in NSScreen.screens {
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
            if (number as? NSNumber)?.uint32Value == displayID {
                return screen.backingScaleFactor
            }
        }
        return 1.0
    }

    /// Capture one window's own content via ScreenCaptureKit's
    /// `desktopIndependentWindow`, so an occluded window still yields its real
    /// content (the frozen desktop would just show whatever is on top).
    static func captureWindow(_ window: SCWindow) async throws -> CapturedWindow {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let rect = filter.contentRect
        let config = SCStreamConfiguration()
        config.width = max(Int((rect.width * scale).rounded()), 1)
        config.height = max(Int((rect.height * scale).rounded()), 1)
        config.showsCursor = false
        config.capturesAudio = false
        config.ignoreShadowsSingleWindow = true

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )
        guard let bytes = rgbaBytes(from: image) else {
            throw CaptureError.encodeFailed
        }
        return CapturedWindow(width: image.width, height: image.height, bytes: bytes)
    }

    /// Draw a `CGImage` into a tightly packed RGBA8 buffer.
    ///
    /// `premultipliedLast` + `byteOrder32Big` lays the bytes out as R,G,B,A —
    /// the same order the Rust texture upload expects. A screenshot is opaque,
    /// so premultiplication is a no-op for the alpha channel.
    private static func rgbaBytes(from image: CGImage) -> [UInt8]? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo =
            CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let drawn: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard
                let context = CGContext(
                    data: buffer.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: colorSpace,
                    bitmapInfo: bitmapInfo
                )
            else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? bytes : nil
    }
}
