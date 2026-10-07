// Recording: the target geometry and small pure helpers.
//
// The backend (`ScreenRecorder`) is macOS 15+ (`SCRecordingOutput`), but the
// target model and the geometry math are plain data, so `--selfcheck` can cover
// them without a screen or a recording.

import CoreGraphics
import ScreenCaptureKit

/// What a recording is pointed at. Built by the overlay from the frozen frame.
enum RecordingTarget {
    /// A whole display (clicked the desktop).
    case display(CapturedDisplay)
    /// A region of a display, in **global logical points** (origin top-left).
    case region(CapturedDisplay, CGRect)
    /// A single window, captured by ScreenCaptureKit regardless of occlusion.
    case window(SCWindow)
}

/// Recording failures worth telling the user about.
enum RecordingError: Error, LocalizedError {
    case unsupportedOS
    case noDisplay
    case cancelled
    case startFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedOS:
            return "录屏需要 macOS 15 或更新版本。"
        case .noDisplay:
            return "找不到要录制的显示器。"
        case .cancelled:
            return "录制已取消。"
        case .startFailed(let reason):
            return reason
        }
    }
}

/// A region's ScreenCaptureKit geometry: the source rectangle in the display's
/// local **points**, plus the native-pixel output size (rounded down to even
/// dimensions, which H.264 requires). Pure → selfcheck.
func recordingRegion(
    selection: CGRect,
    display: CapturedDisplay
) -> (sourceRect: CGRect, width: Int, height: Int) {
    let source = CGRect(
        x: selection.minX - display.origin.x,
        y: selection.minY - display.origin.y,
        width: selection.width,
        height: selection.height
    )
    return (
        source,
        evenPixelCount(selection.width * display.scale),
        evenPixelCount(selection.height * display.scale)
    )
}

/// A whole display's output size at native pixels (even dimensions).
func recordingDisplaySize(display: CapturedDisplay) -> (width: Int, height: Int) {
    (
        evenPixelCount(display.logicalSize.width * display.scale),
        evenPixelCount(display.logicalSize.height * display.scale)
    )
}

/// `value` floored to a positive even integer (≥ 2).
func evenPixelCount(_ value: CGFloat) -> Int {
    let floored = Int(value.rounded(.down))
    return max(floored / 2 * 2, 2)
}

/// `00:00`, `01:05`, `1:01:01` — the control bar's timer. Pure → selfcheck.
func formatDuration(_ seconds: TimeInterval) -> String {
    let total = max(Int(seconds.rounded(.down)), 0)
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, secs)
    }
    return String(format: "%02d:%02d", minutes, secs)
}
