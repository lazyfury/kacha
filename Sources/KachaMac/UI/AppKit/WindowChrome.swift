// Shared AppKit window setup.
//
// Two rules this centralizes:
//  * Programmatic windows are owned by ARC, so AppKit must not also release them
//    on close (a double release crashes in `objc_release`).
//  * The editor / settings windows use a seamless full-size-content chrome:
//    transparent, title-less titlebar so the hosted SwiftUI draws the top bar.

import AppKit

enum WindowChrome {
    /// ARC owns programmatically-created windows; AppKit must not release them
    /// on close too.
    static func own(_ window: NSWindow) {
        window.isReleasedWhenClosed = false
    }

    /// Seamless chrome: the SwiftUI content supplies the title and top bar.
    static func seamless(_ window: NSWindow) {
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
    }
}
