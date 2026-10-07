// Launch arguments.
//
// Usage: `kacha-mac [--smoke-editor | --smoke-export]`
//
// There is deliberately no `--role` / `--session`: the capture flow creates its
// windows from a live session, so a bare window from the command line would have
// nothing to show. The only command-line entry points are the `--smoke-*`
// self-checks, which open and close windows with no screen-recording permission.

import Foundation

struct LaunchOptions {
    /// Debug: run the pure-logic self-check and exit.
    let selfCheck: Bool
    /// Debug: open and close the settings window once, then quit.
    let smokeSettings: Bool
    /// Debug: open and close the editor once, then quit.
    let smokeEditor: Bool
    /// Debug: compose a synthetic capture, copy it to the clipboard, then quit.
    let smokeExport: Bool
    /// Debug: render known text, recognize it with Vision, then quit.
    let smokeOCR: Bool
    /// Debug: open the empty viewer, load an image into it, then quit.
    let smokeViewer: Bool
    /// Debug: open the editor on a generated QR and decode it, then quit.
    let smokeBarcode: Bool

    static func parse(_ arguments: [String]) -> LaunchOptions {
        var selfCheck = false
        var smokeSettings = false
        var smokeEditor = false
        var smokeExport = false
        var smokeOCR = false
        var smokeViewer = false
        var smokeBarcode = false
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--selfcheck":
                selfCheck = true
                index += 1
            case "--smoke-settings":
                smokeSettings = true
                index += 1
            case "--smoke-editor":
                smokeEditor = true
                index += 1
            case "--smoke-export":
                smokeExport = true
                index += 1
            case "--smoke-ocr":
                smokeOCR = true
                index += 1
            case "--smoke-viewer":
                smokeViewer = true
                index += 1
            case "--smoke-barcode":
                smokeBarcode = true
                index += 1
            case "-h", "--help":
                let usage =
                    "用法：kacha-mac [--selfcheck] [--smoke-settings] [--smoke-editor] [--smoke-export] [--smoke-ocr] [--smoke-viewer] [--smoke-barcode]\n"
                FileHandle.standardError.write(Data(usage.utf8))
                exit(0)
            default:
                index += 1
            }
        }
        return LaunchOptions(
            selfCheck: selfCheck,
            smokeSettings: smokeSettings,
            smokeEditor: smokeEditor,
            smokeExport: smokeExport,
            smokeOCR: smokeOCR,
            smokeViewer: smokeViewer,
            smokeBarcode: smokeBarcode
        )
    }
}
