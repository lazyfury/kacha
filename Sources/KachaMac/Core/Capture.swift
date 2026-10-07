// ScreenCaptureKit: freeze every display into a CGImage for the overlay.
//
// Swift owns the capture; the frozen frame is drawn 1:1 by the overlay and is
// the source for the region crop. The image keeps its own colour space, so the
// whole path is colour-managed by Core Graphics.

import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// One display's frozen frame: the image at native pixels plus its geometry in
/// **global logical points** (origin top-left, CoreGraphics space).
struct CapturedDisplay {
    let displayID: CGDirectDisplayID
    let origin: CGPoint
    let logicalSize: CGSize
    /// Backing scale (2.0 on Retina).
    let scale: CGFloat
    /// The captured frame at native pixels.
    let image: CGImage

    /// This display's rectangle in global logical points.
    var globalRect: CGRect { CGRect(origin: origin, size: logicalSize) }
}

/// The frozen displays plus the pickable windows for window-pick mode.
struct CaptureResult {
    let displays: [CapturedDisplay]
    let windows: [SCWindow]
}

/// Capture failures worth telling the user about.
enum CaptureError: Error, LocalizedError {
    case noDisplays
    case captureFailed

    var errorDescription: String? {
        switch self {
        case .noDisplays:
            return "没有找到可截图的显示器。"
        case .captureFailed:
            return "无法抓取屏幕画面。"
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
        // slow part, and a multi-display setup otherwise pays it serially.
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

        // The pickable windows, in **front-to-back z-order**, from CoreGraphics:
        // ScreenCaptureKit's `SCWindow` has no ordering, so its list would
        // highlight an occluded window behind the cursor. Filter to normal-layer,
        // on-screen, opaque-enough windows that are not ours.
        let order = Self.onScreenWindowOrder(excluding: ownPID)
        let byID = Dictionary(
            content.windows.map { ($0.windowID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
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
        // `SCDisplay.width`/`height`/`frame` are all in POINTS; capture at native
        // pixels or the crop is 1x (soft on Retina).
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
        return CapturedDisplay(
            displayID: display.displayID,
            origin: frame.origin,
            logicalSize: frame.size,
            scale: scale,
            image: image
        )
    }

    /// Capture one window's own content via ScreenCaptureKit's
    /// `desktopIndependentWindow`, so an occluded window still yields its real
    /// content (the frozen desktop would just show whatever is on top).
    static func captureWindow(_ window: SCWindow) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let rect = filter.contentRect
        let config = SCStreamConfiguration()
        config.width = max(Int((rect.width * scale).rounded()), 1)
        config.height = max(Int((rect.height * scale).rounded()), 1)
        config.showsCursor = false
        config.capturesAudio = false
        config.ignoreShadowsSingleWindow = true
        return try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )
    }

    /// The on-screen window ids, front-to-back (topmost first), excluding `pid`.
    /// Uses `CGWindowListCopyWindowInfo`, which is the only public source of the
    /// window stacking order.
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
}
