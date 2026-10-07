// kacha — the pure-Swift macOS host.
//
// AppKit owns the windows, Core Graphics renders the UI, and ScreenCaptureKit
// captures the screen. kacha is a menu-bar app (`.accessory`, no Dock icon): it
// lives in the status item and opens windows only on demand.

import AppKit

let options = LaunchOptions.parse(CommandLine.arguments)

if options.selfCheck {
    exit(SelfCheck.run())
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let delegate = AppDelegate(options: options)
application.delegate = delegate
application.run()
