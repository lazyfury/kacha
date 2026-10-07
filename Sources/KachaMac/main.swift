// kacha — the pure-Swift macOS host.
//
// AppKit owns the windows, Core Graphics renders the UI, and ScreenCaptureKit
// captures the screen. kacha is a menu-bar app (`.accessory`, no Dock icon): it
// lives in the status item and opens windows only on demand.
//
// The app state is main-actor isolated; top-level code runs on the main thread,
// so `assumeIsolated` bridges into that isolation.

import AppKit

let options = LaunchOptions.parse(CommandLine.arguments)

MainActor.assumeIsolated {
    if options.selfCheck {
        exit(SelfCheck.run())
    }

    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    let delegate = AppDelegate(options: options)
    application.delegate = delegate
    application.run()
}
