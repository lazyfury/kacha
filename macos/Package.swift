// swift-tools-version:5.9
//
// Swift/macOS front end: AppKit window + CAMetalLayer, with the whole app
// (igui UI, wgpu renderer, capture, editor) linked in from Rust via the
// `ushot_host_*` C ABI.
//
// Build the Rust side first:
//     cargo build                        # -> target/debug/libushot_app.a
//     swift build --package-path macos   # then this package
//
// `USHOT_RUST_PROFILE` selects `debug` (default) or `release`.

import Foundation
import PackageDescription

let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let repoRoot = URL(fileURLWithPath: packageDirectory).deletingLastPathComponent().path
let rustProfile = ProcessInfo.processInfo.environment["USHOT_RUST_PROFILE"] ?? "debug"
let rustLibDir = ProcessInfo.processInfo.environment["USHOT_RUST_LIB_DIR"]
    ?? "\(repoRoot)/target/\(rustProfile)"

let package = Package(
    name: "UShotMac",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "ushot-mac", targets: ["UShotMac"])
    ],
    targets: [
        // The Rust C ABI. SwiftPM generates `module UShotNative` from the
        // umbrella header in `include/`; the symbols themselves come from the
        // Rust static library linked below.
        .target(
            name: "UShotNative",
            path: "Sources/UShotNative"
        ),
        .executableTarget(
            name: "UShotMac",
            dependencies: ["UShotNative"],
            path: "Sources/UShotMac",
            linkerSettings: [
                .unsafeFlags(["-L", rustLibDir, "-lushot_app"]),
                .linkedLibrary("c++"),
                .linkedFramework("AppKit"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Carbon"),
            ]
        ),
    ]
)
