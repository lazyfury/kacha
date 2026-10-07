// ushot — the Swift/macOS host.
//
// Swift owns the windows and their CAMetalLayers, and forwards native events;
// the igui UI and the wgpu renderer are all Rust (`ushot-app`), linked through
// the `ushot_host_*` C ABI. Swift replaces `winit` and nothing else.
//
// ushot is a menu-bar app (`.accessory`, no Dock icon): it lives in the status
// item and opens windows only on demand.

import AppKit

let options = LaunchOptions.parse(CommandLine.arguments)

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let delegate = AppDelegate(options: options)
application.delegate = delegate
application.run()
