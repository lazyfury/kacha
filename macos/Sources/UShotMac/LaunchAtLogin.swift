// Launch at login via `SMAppService` (macOS 13+). Only meaningful when running
// from a real `.app` bundle.

import Foundation
import ServiceManagement

enum LaunchAtLogin {
    /// Whether the app is running from a bundle (a SwiftPM binary is not).
    static var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Enable or disable launch at login. Returns an error to show the user.
    static func set(_ enabled: Bool) -> Error? {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error
        }
    }
}
