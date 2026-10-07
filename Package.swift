// swift-tools-version:5.9
//
// Pure-Swift kacha: AppKit windows + Core Graphics rendering + ScreenCaptureKit.
// The whole app (windows, events, capture, UI, image work) is Swift; there is no
// Rust static library and no C ABI.

import PackageDescription

let package = Package(
    name: "KachaMac",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "kacha-mac", targets: ["KachaMac"])
    ],
    targets: [
        .executableTarget(
            name: "KachaMac",
            path: "Sources/KachaMac",
            linkerSettings: [
                // SwiftPM records the deployment target as the linked SDK version
                // in `LC_BUILD_VERSION`, which makes macOS treat the app as legacy
                // and draw the pre-macOS-26 controls. Pin the platform version so
                // the recorded SDK stays macOS 26 and the app adopts the macOS 26
                // (Liquid Glass) appearance. minos keeps the 14.0 deployment floor.
                .unsafeFlags([
                    "-Xlinker", "-platform_version",
                    "-Xlinker", "macos",
                    "-Xlinker", "14.0",
                    "-Xlinker", "26.0",
                ]),
                .linkedFramework("AppKit"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("VisionKit"),
            ]
        ),
    ]
)
