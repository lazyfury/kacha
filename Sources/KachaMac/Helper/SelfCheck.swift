// `--selfcheck`: pure-logic assertions with no window, no screen recording and
// no XCTest (this toolchain is Command Line Tools only). Exits non-zero on the
// first failing check so it can gate a build.

import AppKit
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

@MainActor
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
        checkHotkeys(check)
        checkExport(check)
        checkOCR(check)
        checkBarcode(check)
        checkRecording(check)
        checkSound(check)

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

        // Every handle is hit at its centre and nowhere else inside the rect.
        for handle in Selection.Handle.allCases {
            guard let center = Selection.handleCenters(start).first(where: { $0.0 == handle })?.1
            else {
                check(false, "handle \(handle) has a centre")
                continue
            }
            check(Selection.handleAt(start, center) == handle, "handleAt hits \(handle)")
        }
        check(Selection.handleAt(start, CGPoint(x: 200, y: 150)) == nil, "handleAt misses the interior")
        check(Selection.handleAt(start, CGPoint(x: 999, y: 999)) == nil, "handleAt misses outside")
    }

    private static func checkCompose(_ check: (Bool, String) -> Void) {
        // One Retina display: 20×10 logical points → 40×20 px.
        guard
            let retina = display(
                origin: .zero,
                logical: CGSize(width: 100, height: 50),
                scale: 2,
                color: CGColor(srgbRed: 0.1, green: 0.2, blue: 0.3, alpha: 1)
            ),
            let retinaLeft = display(
                origin: .zero,
                logical: CGSize(width: 200, height: 100),
                scale: 2,
                color: CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
            ),
            let plainRight = display(
                origin: CGPoint(x: 200, y: 0),
                logical: CGSize(width: 100, height: 100),
                scale: 1,
                color: CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
            )
        else {
            check(false, "could not build the test displays")
            return
        }

        let crop = Compose.compose([retina], selection: CGRect(x: 10, y: 10, width: 20, height: 10))
        check(crop?.width == 40 && crop?.height == 20, "retina region crops at native scale")
        if let crop {
            let mosaic = Mosaic.make(crop, block: 4)
            check(mosaic != nil, "mosaic image builds")
            check(mosaic?.width == (crop.width + 3) / 4, "mosaic has one column per block")
            check(mosaic?.height == (crop.height + 3) / 4, "mosaic has one row per block")
        }

        // Mixed DPI, anchor on the 2x display → output at 2x.
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

        // The shape tools must render too.
        state.annotations = [
            Annotation(tool: .ellipse, points: corners, color: [0, 1, 0, 1], stroke: 2, text: ""),
        ]
        check(canvas.renderExport() != plain, "ellipse changes the exported image")
        state.annotations = [
            Annotation(tool: .line, points: corners, color: [0, 1, 0, 1], stroke: 2, text: ""),
        ]
        check(canvas.renderExport() != plain, "line changes the exported image")
        state.annotations = [
            Annotation(
                tool: .number,
                points: [CGPoint(x: 20, y: 10)],
                color: [1, 0, 0, 1],
                stroke: 18,
                text: "1"
            ),
        ]
        check(canvas.renderExport() != plain, "number changes the exported image")

        // Numbering follows the highest existing badge.
        check(Annotation.nextNumber(in: []) == 1, "next number starts at 1")
        let badges = [
            Annotation(tool: .number, points: [.zero], color: [1, 0, 0, 1], stroke: 18, text: "1"),
            Annotation(tool: .number, points: [.zero], color: [1, 0, 0, 1], stroke: 18, text: "3"),
        ]
        check(Annotation.nextNumber(in: badges) == 4, "next number follows the max")
        check(
            Tool.allCases.contains(.ellipse) && Tool.allCases.contains(.line)
                && Tool.allCases.contains(.number),
            "shape and number tools exist"
        )

        check(!AnnotationPalette.colors.isEmpty, "palette has colours")
        check(
            AnnotationPalette.strokePresets.contains { $0.factor == 1 },
            "palette has a standard stroke"
        )

        // Re-editing text must not crash when an undo removed the annotation the
        // field still points at (the stale-index guard).
        let editing = EditorState()
        editing.annotations = [
            Annotation(tool: .text, points: [.zero], color: [1, 0, 0, 1], stroke: 18, text: "a"),
        ]
        check(!editing.replaceText(at: 5, with: "x"), "stale text edit is ignored")
        check(editing.replaceText(at: 0, with: "b"), "text edit replaces in place")
        check(editing.annotations[0].text == "b", "text edit wrote the new value")
        check(editing.replaceText(at: 0, with: ""), "empty text edit deletes")
        check(editing.annotations.isEmpty, "empty text edit removed the annotation")
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

    /// The menu key-equivalent rule must only accept a single letter/digit.
    private static func checkHotkeys(_ check: (Bool, String) -> Void) {
        if let equivalent = Hotkey.default.menuKeyEquivalent {
            check(equivalent.key == "a", "default hotkey maps to menu key 'a'")
            check(
                equivalent.modifiers == [.command, .shift],
                "default hotkey keeps its modifiers"
            )
        } else {
            check(false, "default hotkey has a menu key equivalent")
        }
        let arrow = Hotkey(keyCode: 123, modifiers: [.command], keyLabel: "←")
        check(arrow.menuKeyEquivalent == nil, "non-alphanumeric labels have no menu equivalent")

        // The delayed-capture presets start at zero and ascend (menu order).
        check(
            Preferences.delayChoices.first == 0
                && Preferences.delayChoices == Preferences.delayChoices.sorted(),
            "delay choices start at 0 and ascend"
        )
    }

    /// Save names must never collide when writing straight into a directory.
    private static func checkExport(_ check: (Bool, String) -> Void) {
        check(
            Export.deduplicatedName("kacha.png", existing: []) == "kacha.png",
            "a free save name is unchanged"
        )
        check(
            Export.deduplicatedName("kacha.png", existing: ["kacha.png"]) == "kacha 2.png",
            "a taken save name gets a numeric suffix"
        )
        check(
            Export.deduplicatedName("kacha.png", existing: ["kacha.png", "kacha 2.png"])
                == "kacha 3.png",
            "the suffix keeps counting past the first collision"
        )
        check(
            Export.timestampedName().hasPrefix("kacha-") && Export.timestampedName().hasSuffix(".png"),
            "the timestamped name is a kacha PNG"
        )
        check(
            Export.deduplicatedName("kacha", existing: ["kacha"]) == "kacha 2",
            "a name without an extension still gets a suffix"
        )
        check(
            Export.deduplicatedName(
                "kacha-20240101-000000.png",
                existing: ["kacha-20240101-000000.png"]
            ) == "kacha-20240101-000000 2.png",
            "a timestamped name gets a suffix before the extension"
        )
    }

    /// `joinLines` keeps or drops the visual line breaks for the OCR sheet.
    private static func checkOCR(_ check: (Bool, String) -> Void) {
        check(
            OCR.joinLines(["a", "b"], merged: false) == "a\nb",
            "joinLines keeps newlines when not merged"
        )
        check(
            OCR.joinLines(["hello", "world"], merged: true) == "hello world",
            "joinLines joins Latin lines with a space"
        )
        check(
            OCR.joinLines(["你好", "世界"], merged: true) == "你好世界",
            "joinLines joins CJK lines without a space"
        )
    }

    /// A generated QR must round-trip through Vision's barcode detector.
    private static func checkBarcode(_ check: (Bool, String) -> Void) {
        guard let qr = qrImage("KACHA-7788"), let composed = Compose.composed(from: qr) else {
            check(false, "could not render the test QR")
            return
        }
        let codes = BarcodeReader.detectSync(in: composed.image)
        check(codes.contains { $0.payload == "KACHA-7788" }, "detects a QR payload")
    }

    /// A QR code bitmap via Core Image, for the barcode check.
    private static func qrImage(_ payload: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }

    /// Recording geometry and the control-bar timer format.
    private static func checkRecording(_ check: (Bool, String) -> Void) {
        check(formatDuration(0) == "00:00", "duration formats zero")
        check(formatDuration(65) == "01:05", "duration formats minutes")
        check(formatDuration(3661) == "1:01:01", "duration formats hours")

        guard
            let display = display(
                origin: CGPoint(x: 100, y: 0),
                logical: CGSize(width: 200, height: 100),
                scale: 2,
                color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
            )
        else {
            check(false, "could not build the recording display")
            return
        }
        let region = recordingRegion(
            selection: CGRect(x: 120, y: 10, width: 30, height: 20),
            display: display
        )
        check(
            region.sourceRect == CGRect(x: 20, y: 10, width: 30, height: 20),
            "region maps to display-local points"
        )
        check(region.width == 60 && region.height == 40, "region outputs native pixels")
        let size = recordingDisplaySize(display: display)
        check(size.width == 400 && size.height == 200, "display outputs native pixels")
        check(
            Export.timestampedName(extension: "mp4").hasSuffix(".mp4"),
            "movie name uses the mp4 extension"
        )
        check(RecordingContainer.mp4.fileExtension == "mp4", "container maps to a file extension")
        check(
            RecordingAudio.allCases == [.none, .system, .microphone, .systemAndMicrophone],
            "audio sources are none / system / microphone / both"
        )
        check(RecordingFrameRate.allCases.map(\.rawValue) == [30, 60], "frame rates are 30 / 60")
        check(RecordingContainer.mov.fileExtension == "mov", "mov container maps to mov")
        check(
            RecordingAudio.none.capturesSystemAudio == false
                && RecordingAudio.none.capturesMicrophone == false
                && RecordingAudio.system.capturesSystemAudio
                && RecordingAudio.system.capturesMicrophone == false
                && RecordingAudio.microphone.capturesMicrophone
                && RecordingAudio.microphone.capturesSystemAudio == false
                && RecordingAudio.systemAndMicrophone.capturesSystemAudio
                && RecordingAudio.systemAndMicrophone.capturesMicrophone,
            "audio source flags match the source"
        )
        check(
            RecordingConfig().frameRate == .fps30
                && RecordingConfig().codec == .h264
                && RecordingConfig().container == .mp4
                && RecordingConfig().audio == .none,
            "recording config defaults are 30 / h264 / mp4 / no audio"
        )
    }

    /// The fallback must always resolve; the exact system capture sound is not a
    /// documented path and may legitimately move between macOS releases, so it is
    /// only covered by the "a source resolves" check below.
    private static func checkSound(_ check: (Bool, String) -> Void) {
        check(
            NSSound(named: NSSound.Name(ShotSound.fallbackName)) != nil,
            "fallback sound '\(ShotSound.fallbackName)' exists"
        )
        check(ShotSound.sound != nil, "a shutter sound source resolves")
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
    ) -> CapturedDisplay? {
        let width = Int(logical.width * scale)
        let height = Int(logical.height * scale)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard
            let ctx = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            return nil
        }
        ctx.setFillColor(color)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = ctx.makeImage() else { return nil }
        return CapturedDisplay(
            displayID: 1,
            origin: origin,
            logicalSize: logical,
            scale: scale,
            image: image
        )
    }

    private static func rgb(_ composed: ComposedImage, _ x: Int) -> [UInt8] {
        let i = x * 4
        return [composed.pixels[i], composed.pixels[i + 1], composed.pixels[i + 2]]
    }
}
