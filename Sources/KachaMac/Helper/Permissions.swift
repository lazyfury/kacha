// Screen-recording and microphone (TCC) permissions.
//
// ScreenCaptureKit needs the user to grant "Screen Recording". The first request
// shows the system prompt; after granting, macOS normally requires a relaunch.
// The microphone is a separate TCC permission and needs a usage description.

import AppKit
import AVFoundation
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

/// Microphone (TCC) permission, shown in Settings and used by `MicRecorder`.
enum MicrophonePermission {
    enum Status {
        case authorized
        case denied
        case notDetermined
        case restricted
        /// No `NSMicrophoneUsageDescription` (e.g. the bare binary).
        case unavailable
    }

    /// The current authorization. `.unavailable` when the app has no usage
    /// description — requesting access without one crashes the process.
    static var status: Status {
        guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil
        else {
            return .unavailable
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    /// Request access. Only the first call (when `.notDetermined`) shows the
    /// system prompt; later calls just report the current state.
    @discardableResult
    static func request() async -> Bool {
        guard status == .notDetermined else { return status == .authorized }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Open System Settings at Privacy & Security › Microphone.
    static func openSystemSettings() {
        let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        )
        if let url {
            NSWorkspace.shared.open(url)
        }
    }
}
