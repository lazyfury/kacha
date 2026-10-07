// Launch arguments.
//
// Usage: `ushot-mac [--smoke-editor | --smoke-export]`
//
// There is deliberately no `--role` / `--session`: the capture flow creates its
// windows from a live session, so a bare window from the command line would have
// nothing to show. The only command-line entry points are the `--smoke-*`
// self-checks, which open and close windows with no screen-recording permission.

import Foundation
import UShotNative

struct LaunchOptions {
    /// Debug: open and close the editor once, then quit.
    let smokeEditor: Bool
    /// Debug: compose a synthetic capture, copy it to the clipboard, then quit.
    let smokeExport: Bool

    static func parse(_ arguments: [String]) -> LaunchOptions {
        var smokeEditor = false
        var smokeExport = false
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--smoke-editor":
                smokeEditor = true
                index += 1
            case "--smoke-export":
                smokeExport = true
                index += 1
            case "-h", "--help":
                let usage = "用法：ushot-mac [--smoke-editor] [--smoke-export]\n"
                FileHandle.standardError.write(Data(usage.utf8))
                exit(0)
            default:
                index += 1
            }
        }
        return LaunchOptions(smokeEditor: smokeEditor, smokeExport: smokeExport)
    }
}
