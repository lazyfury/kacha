// Screen-recording (TCC) permission.
//
// ScreenCaptureKit needs the user to grant "Screen Recording". The first request
// shows the system prompt; after granting, macOS normally requires a relaunch.

import AppKit
import CoreGraphics

enum ScreenPermission {
    /// True when screen recording is already authorised.
    static func isGranted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Request the permission. Returns true when it was already granted;
    /// otherwise it triggers the system prompt and returns false (the user must
    /// grant it and relaunch).
    @discardableResult
    static func request() -> Bool {
        if isGranted() { return true }
        CGRequestScreenCaptureAccess()
        return isGranted()
    }

    /// Open System Settings at Privacy & Security › Screen Recording.
    static func openSystemSettings() {
        let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        )
        if let url {
            NSWorkspace.shared.open(url)
        }
    }
}
