// `--selfcheck`: pure-logic assertions with no window, no screen recording and
// no XCTest (this toolchain is Command Line Tools only). Exits non-zero on the
// first failing check so it can gate a build.

import AppKit
import CoreGraphics
import Foundation

enum SelfCheck {
    static func run() -> Int32 {
        var failures = 0
        func check(_ condition: Bool, _ message: String) {
            if !condition {
                failures += 1
                FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            }
        }
        checkSelection(check)
        checkCompose(check)
        checkGeometry(check)
        checkColor(check)
        checkAnnotations(check)
        checkSymbols(check)

        print(failures == 0 ? "selfcheck: ok" : "selfcheck: \(failures) failure(s)")
        return failures == 0 ? 0 : 1
    }

    private static func checkSelection(_ check: (Bool, String) -> Void) {
        // A drag normalizes in either direction.
        for (from, to) in [
            (CGPoint(x: 10, y: 20), CGPoint(x: 50, y: 80)),
            (CGPoint(x: 50, y: 80), CGPoint(x: 10, y: 20)),
        ] {
            let (drag, _) = Selection.begin(current: nil, at: from)
            let rect = Selection.update(drag, to: to, current: nil)
            check(rect == CGRect(x: 10, y: 20, width: 40, height: 60), "drag normalizes")
        }

        // A click without a drag clears the selection.
        let (clickDrag, initial) = Selection.begin(current: nil, at: CGPoint(x: 5, y: 5))
        check(Selection.finish(clickDrag, current: initial) == nil, "click clears selection")

        // Move and resize.
        let start = CGRect(x: 100, y: 100, width: 200, height: 100)
        let (move, _) = Selection.begin(current: start, at: CGPoint(x: 200, y: 150))
        check(
            Selection.update(move, to: CGPoint(x: 230, y: 160), current: start)
                == CGRect(x: 130, y: 110, width: 200, height: 100),
            "move translates the selection"
        )
        let (resize, _) = Selection.begin(current: start, at: CGPoint(x: 300, y: 200))
        check(
            Selection.update(resize, to: CGPoint(x: 250, y: 260), current: start)
                == CGRect(x: 100, y: 100, width: 150, height: 160),
            "SE handle resizes"
        )
        check(
            Selection.resize(start, handle: .se, to: CGPoint(x: 50, y: 40))
                == CGRect(x: 50, y: 40, width: 50, height: 60),
            "resize across the opposite edge stays normalized"
        )

        // Mask leaves a hole.
        let viewport = CGRect(x: 0, y: 0, width: 100, height: 100)
        let mask = Selection.maskRects(
            viewport: viewport,
            selection: CGRect(x: 20, y: 30, width: 40, height: 50)
        )
        check(mask[0] == CGRect(x: 0, y: 0, width: 100, height: 30), "mask above")
        check(mask[1] == CGRect(x: 0, y: 80, width: 100, height: 20), "mask below")
        check(mask[2] == CGRect(x: 0, y: 30, width: 20, height: 50), "mask left")
        check(mask[3] == CGRect(x: 60, y: 30, width: 40, height: 50), "mask right")
        check(Selection.maskRects(viewport: viewport, selection: nil)[0] == viewport, "no selection dims all")
    }

    private static func checkCompose(_ check: (Bool, String) -> Void) {
        // One Retina display: 20×10 logical points → 40×20 px.
        let retina = display(
            origin: .zero,
            logical: CGSize(width: 100, height: 50),
            scale: 2,
            color: CGColor(srgbRed: 0.1, green: 0.2, blue: 0.3, alpha: 1)
        )
        let crop = Compose.compose([retina], selection: CGRect(x: 10, y: 10, width: 20, height: 10))
        check(crop?.width == 40 && crop?.height == 20, "retina region crops at native scale")
        if let crop {
            let mosaic = Mosaic.make(crop, block: 4)
            check(mosaic != nil, "mosaic image builds")
            check(mosaic?.width == (crop.width + 3) / 4, "mosaic has one column per block")
            check(mosaic?.height == (crop.height + 3) / 4, "mosaic has one row per block")
        }

        // Mixed DPI, anchor on the 2x display → output at 2x.
        let retinaLeft = display(
            origin: .zero,
            logical: CGSize(width: 200, height: 100),
            scale: 2,
            color: CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        )
        let plainRight = display(
            origin: CGPoint(x: 200, y: 0),
            logical: CGSize(width: 100, height: 100),
            scale: 1,
            color: CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
        )
        if let mixed = Compose.compose(
            [retinaLeft, plainRight],
            selection: CGRect(x: 180, y: 0, width: 40, height: 10)
        ) {
            check(mixed.width == 80 && mixed.height == 20, "mixed DPI anchored on 2x outputs at 2x")
            check(rgb(mixed, 0) == [255, 0, 0], "mixed left is the retina display")
            check(rgb(mixed, 79) == [0, 0, 255], "mixed right is the plain display")
        } else {
            check(false, "mixed DPI compose returned nil")
        }
    }

    private static func checkGeometry(_ check: (Bool, String) -> Void) {
        check(
            containFit((200, 100), in: CGRect(x: 0, y: 0, width: 100, height: 100))
                == CGRect(x: 0, y: 25, width: 100, height: 50),
            "containFit letterboxes a wide image"
        )

        let rect = CGRect(x: 10, y: 20, width: 400, height: 200)
        let screen = toScreen(rect, (800, 400), CGPoint(x: 200, y: 100))
        check(screen == CGPoint(x: 110, y: 70), "toScreen maps image pixels")
        let back = toImage(rect, (800, 400), screen)
        check(abs(back.x - 200) < 0.001 && abs(back.y - 100) < 0.001, "toImage round-trips")

        check(defaultStroke((3840, 2160)) > defaultStroke((1600, 1000)), "stroke scales with the image")
        check(defaultTextSize((3840, 2160)) > defaultTextSize((1600, 1000)), "text scales with the image")
        check(defaultStroke((100, 100)) >= 3, "stroke is clamped up")
        check(defaultTextSize((100, 100)) >= 14, "text is clamped up")
        check(defaultMarkerStroke((3840, 2160)) >= 16, "marker stroke is at least 16px")
        check(defaultMarkerStroke((100, 100)) >= 16, "marker stroke is clamped to 16px")
        check(defaultMarkerStroke((3840, 2160)) > defaultMarkerStroke((1600, 1000)), "marker scales")
        check(mosaicBlock((3840, 2160)) >= 8, "mosaic block is at least 8px")
    }

    /// The marker tools must actually change the exported pixels.
    private static func checkAnnotations(_ check: (Bool, String) -> Void) {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard
            let ctx = CGContext(
                data: nil,
                width: 40,
                height: 20,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            check(false, "annotation test context")
            return
        }
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 20, y: 0, width: 20, height: 20))
        guard let image = ctx.makeImage() else {
            check(false, "annotation test image")
            return
        }

        let source = CapturedDisplay(
            displayID: 1,
            origin: .zero,
            logicalSize: CGSize(width: 20, height: 10),
            scale: 2,
            image: image
        )
        guard
            let composed = Compose.compose(
                [source],
                selection: CGRect(x: 0, y: 0, width: 20, height: 10)
            )
        else {
            check(false, "annotation test compose")
            return
        }

        let session = CaptureSession()
        session.composed = composed
        let state = EditorState()
        let canvas = EditorCanvasView(session: session, state: state)
        guard let plain = canvas.renderExport() else {
            check(false, "plain export")
            return
        }

        let stroke = defaultMarkerStroke((40, 20))
        let line = [CGPoint(x: 4, y: 10), CGPoint(x: 36, y: 10)]
        state.annotations = [
            Annotation(tool: .mosaic, points: line, color: [1, 0, 0, 1], stroke: stroke, text: ""),
        ]
        guard let mosaicked = canvas.renderExport() else {
            check(false, "mosaic export")
            return
        }
        check(mosaicked != plain, "mosaic changes the exported image")

        state.annotations = [
            Annotation(
                tool: .highlighter,
                points: line,
                color: [1, 0.9, 0.2, 0.35],
                stroke: stroke,
                text: ""
            ),
        ]
        guard let highlighted = canvas.renderExport() else {
            check(false, "highlighter export")
            return
        }
        check(highlighted != plain, "highlighter changes the exported image")

        // A filled rectangle must differ from an outline.
        let corners = [CGPoint(x: 4, y: 4), CGPoint(x: 36, y: 16)]
        state.annotations = [
            Annotation(
                tool: .rectangle,
                points: corners,
                color: [0, 1, 0, 1],
                stroke: 2,
                text: "",
                filled: false
            ),
        ]
        guard let outline = canvas.renderExport() else {
            check(false, "rectangle export")
            return
        }
        check(outline != plain, "rectangle changes the exported image")
        state.annotations[0].filled = true
        guard let filled = canvas.renderExport() else {
            check(false, "filled rectangle export")
            return
        }
        check(filled != outline, "filled rectangle differs from the outline")

        check(!AnnotationPalette.colors.isEmpty, "palette has colours")
        check(
            AnnotationPalette.strokePresets.contains { $0.factor == 1 },
            "palette has a standard stroke"
        )
    }

    /// Every toolbar SF Symbol must resolve, so a typo cannot silently fall back.
    private static func checkSymbols(_ check: (Bool, String) -> Void) {
        for symbol in ToolbarSymbol.all {
            check(
                NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil,
                "SF Symbol '\(symbol)' exists"
            )
        }
    }

    private static func checkColor(_ check: (Bool, String) -> Void) {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard
            let ctx = CGContext(
                data: nil,
                width: 2,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 8,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            check(false, "could not build the colour test context")
            return
        }
        ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 1))
        guard let image = ctx.makeImage() else {
            check(false, "could not build the colour test image")
            return
        }
        let color = ColorPicker.pixel(image, x: 0, y: 0)
        check(color != nil, "pixel samples a colour")
        check(color?.hexString == "#336699", "hex is #336699, got \(color?.hexString ?? "nil")")
        check(ColorPicker.pixel(image, x: 5, y: 0) == nil, "out-of-bounds pixel is nil")
    }

    private static func display(
        origin: CGPoint,
        logical: CGSize,
        scale: CGFloat,
        color: CGColor
    ) -> CapturedDisplay {
        let width = Int(logical.width * scale)
        let height = Int(logical.height * scale)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(color)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return CapturedDisplay(
            displayID: 1,
            origin: origin,
            logicalSize: logical,
            scale: scale,
            image: ctx.makeImage()!
        )
    }

    private static func rgb(_ composed: ComposedImage, _ x: Int) -> [UInt8] {
        let i = x * 4
        return [composed.pixels[i], composed.pixels[i + 1], composed.pixels[i + 2]]
    }
}
