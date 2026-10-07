// The capture session: the shared state a capture's windows use.
//
// Created before the overlay panels and dropped when the capture finishes. Holds
// the frozen displays, the current selection and the composed image.

import CoreGraphics
import ScreenCaptureKit

/// What the editor asks the shell to do with the finished image.
enum EditorAction {
    case copy
    case save
    case pin
    case close
}

/// What the overlay is for.
enum OverlayMode {
    /// Region / window / full-screen capture.
    case capture
    /// Pick a pixel colour and copy its hex.
    case colorPicker
}

final class CaptureSession {
    private(set) var displays: [CGDirectDisplayID: CapturedDisplay] = [:]
    /// What the overlay does with a click.
    var mode: OverlayMode = .capture
    /// The current selection in global logical points (origin top-left).
    var selection: CGRect?
    /// The cropped selection, filled by `confirm()`.
    var composed: ComposedImage?
    /// The window under the cursor (global logical points), for window picking.
    var hover: CGRect?

    func setDisplay(_ display: CapturedDisplay) {
        displays[display.displayID] = display
    }

    func display(_ id: CGDirectDisplayID) -> CapturedDisplay? {
        displays[id]
    }

    /// The displays in ascending id order.
    var displayList: [CapturedDisplay] {
        displays.values.sorted { $0.displayID < $1.displayID }
    }

    /// Confirm the current selection: crop it out of the frozen frames.
    func confirm() {
        guard let selection, Selection.usable(selection) else { return }
        composed = Compose.compose(displayList, selection: selection)
    }
}
