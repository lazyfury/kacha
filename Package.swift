// swift-tools-version:5.9
//
// Pure-Swift ushot: AppKit windows + Core Graphics rendering + ScreenCaptureKit.
// The whole app (windows, events, capture, UI, image work) is Swift; there is no
// Rust static library and no C ABI.

import PackageDescription

let package = Package(
    name: "UShotMac",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "ushot-mac", targets: ["UShotMac"])
    ],
    targets: [
        .executableTarget(
            name: "UShotMac",
            path: "Sources/UShotMac",
            linkerSettings: [
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
