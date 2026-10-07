// The editor canvas: draws the composed image and the annotations, maps between
// image pixels and view points, and turns mouse input into annotations.
//
// All annotation coordinates are in **image pixels**; the canvas letterboxes the
// image and records its on-screen rect. The same `drawContent` routine renders
// the on-screen preview and the native-pixel export, so they match exactly.

import AppKit
import CoreGraphics
import CoreText

/// The editor's shared state.
final class EditorState {
    var tool: Tool = .rectangle
    /// RGBA in 0...1.
    var color: [CGFloat] = [1, 0.2, 0.2, 1]
    /// Stroke width in image pixels, for the shape tools.
    var stroke: CGFloat = 2
    /// Font size in image pixels, for the text tool.
    var textSize: CGFloat = 18
    var annotations: [Annotation] = []
    var redo: [Annotation] = []
    var draft: Annotation?
    /// The image's on-screen rect, recorded by the last paint.
    var imageRect: CGRect = .zero

    func undo() {
        if let last = annotations.popLast() {
            redo.append(last)
        }
    }

    func redoLast() {
        if let last = redo.popLast() {
            annotations.append(last)
        }
    }
}

/// The largest rectangle of `image`'s aspect ratio that fits centred in `area`.
func containFit(_ image: (Int, Int), in area: CGRect) -> CGRect? {
    guard image.0 > 0, image.1 > 0, area.width > 0, area.height > 0 else { return nil }
    let scale = min(area.width / CGFloat(image.0), area.height / CGFloat(image.1))
    let size = CGSize(width: CGFloat(image.0) * scale, height: CGFloat(image.1) * scale)
    return CGRect(
        x: area.midX - size.width / 2,
        y: area.midY - size.height / 2,
        width: size.width,
        height: size.height
    )
}

/// Screen point → image pixel.
func toImage(_ rect: CGRect, _ image: (Int, Int), _ p: CGPoint) -> CGPoint {
    CGPoint(
        x: (p.x - rect.minX) / rect.width * CGFloat(image.0),
        y: (p.y - rect.minY) / rect.height * CGFloat(image.1)
    )
}

/// Image pixel → screen point.
func toScreen(_ rect: CGRect, _ image: (Int, Int), _ p: CGPoint) -> CGPoint {
    CGPoint(
        x: rect.minX + p.x / CGFloat(image.0) * rect.width,
        y: rect.minY + p.y / CGFloat(image.1) * rect.height
    )
}

/// Clamp an image-space point to the image bounds.
func clampToImage(_ p: CGPoint, _ image: (Int, Int)) -> CGPoint {
    CGPoint(
        x: min(max(p.x, 0), CGFloat(image.0)),
        y: min(max(p.y, 0), CGFloat(image.1))
    )
}

/// Default annotation stroke for an image, in image pixels.
func defaultStroke(_ image: (Int, Int)) -> CGFloat {
    min(max(imageDiagonal(image) / 500, 3), 10)
}

/// Default brush width for the marker tools (highlighter / mosaic), in image
/// pixels. Deliberately thick — a marker below 16 px reads as a plain line.
func defaultMarkerStroke(_ image: (Int, Int)) -> CGFloat {
    min(max(imageDiagonal(image) / 100, 16), 160)
}

/// Mosaic cell size for an image, in image pixels.
func mosaicBlock(_ image: (Int, Int)) -> Int {
    min(max(Int(imageDiagonal(image) / 120), 8), 64)
}

/// Default text size for an image, in image pixels.
func defaultTextSize(_ image: (Int, Int)) -> CGFloat {
    min(max(imageDiagonal(image) / 50, 14), 96)
}

private func imageDiagonal(_ image: (Int, Int)) -> CGFloat {
    let w = CGFloat(image.0)
    let h = CGFloat(image.1)
    return (w * w + h * h).squareRoot()
}

/// The canvas: composed image + annotations, with the editor's mouse handling.
final class EditorCanvasView: NSView, NSTextFieldDelegate {
    let session: CaptureSession
    let state: EditorState

    private var dragging = false
    private var textField: NSTextField?
    private var editingPosition: CGPoint?
    /// Block-averaged copy of the composed image, built once for the mosaic tool.
    private var mosaicCache: (block: Int, image: CGImage)?

    init(session: CaptureSession, state: EditorState) {
        self.session = session
        self.state = state
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1).cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("EditorCanvasView is created programmatically") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private var image: (Int, Int) {
        guard let composed = session.composed else { return (0, 0) }
        return (composed.width, composed.height)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let image = self.image
        let imageRect = containFit(image, in: bounds) ?? .zero
        state.imageRect = imageRect
        drawContent(into: ctx, bounds: bounds, imageRect: imageRect)
    }

    /// Draw the composed image and the annotations into `ctx` (assumed to be a
    /// top-left, y-down context). `imageRect` is where the image is drawn.
    func drawContent(into ctx: CGContext, bounds: CGRect, imageRect: CGRect) {
        ctx.setFillColor(NSColor(calibratedWhite: 0.08, alpha: 1).cgColor)
        ctx.fill(bounds)
        guard let composed = session.composed else { return }
        drawImage(ctx, composed.image, in: imageRect)
        let image = (composed.width, composed.height)
        for annotation in state.annotations {
            drawAnnotation(ctx, annotation, imageRect: imageRect, image: image)
        }
        if let draft = state.draft {
            drawAnnotation(ctx, draft, imageRect: imageRect, image: image)
        }
    }

    /// Draw a `CGImage` upright into a top-left, y-down context.
    private func drawImage(_ ctx: CGContext, _ image: CGImage, in rect: CGRect) {
        ctx.saveGState()
        ctx.interpolationQuality = .high
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        ctx.restoreGState()
    }

    // MARK: - Annotations

    private func drawAnnotation(
        _ ctx: CGContext,
        _ annotation: Annotation,
        imageRect: CGRect,
        image: (Int, Int)
    ) {
        let color = annotation.color
        let cgColor = CGColor(srgbRed: color[0], green: color[1], blue: color[2], alpha: color[3])
        let scale = imageRect.width / CGFloat(max(image.0, 1))
        let width = max(annotation.stroke * scale, 1)
        let points = annotation.points.map { toScreen(imageRect, image, $0) }

        switch annotation.tool {
        case .rectangle:
            if let rect = rectFrom(points) {
                ctx.setStrokeColor(cgColor)
                ctx.setLineWidth(width)
                ctx.stroke(rect)
            }
        case .arrow:
            if let a = points.first, let b = points.dropFirst().first {
                ctx.setStrokeColor(cgColor)
                ctx.setLineWidth(width)
                ctx.beginPath()
                ctx.move(to: a)
                ctx.addLine(to: b)
                ctx.strokePath()
                let dx = b.x - a.x
                let dy = b.y - a.y
                let length = (dx * dx + dy * dy).squareRoot()
                if length > 1 {
                    let ux = dx / length
                    let uy = dy / length
                    let head = max(12, width * 4)
                    for angle in [150.0, -150.0].map({ $0 * .pi / 180 }) {
                        let sin = Foundation.sin(angle)
                        let cos = Foundation.cos(angle)
                        let bx = ux * cos - uy * sin
                        let by = ux * sin + uy * cos
                        ctx.beginPath()
                        ctx.move(to: b)
                        ctx.addLine(to: CGPoint(x: b.x + bx * head, y: b.y + by * head))
                        ctx.strokePath()
                    }
                }
            }
        case .pen, .highlighter:
            guard points.count >= 2 else { break }
            ctx.setStrokeColor(cgColor)
            ctx.setLineWidth(width)
            ctx.setLineJoin(.round)
            ctx.setLineCap(.round)
            ctx.beginPath()
            ctx.move(to: points[0])
            for p in points.dropFirst() {
                ctx.addLine(to: p)
            }
            ctx.strokePath()
        case .text:
            if let position = points.first {
                drawText(ctx, annotation.text, topLeft: position, size: max(annotation.stroke * scale, 8), color: cgColor)
            }
        case .mosaic:
            drawMosaic(ctx, annotation, imageRect: imageRect, image: image)
        }
    }

    private func rectFrom(_ points: [CGPoint]) -> CGRect? {
        guard let a = points.first, let b = points.dropFirst().first else { return nil }
        return CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(a.x - b.x),
            height: abs(a.y - b.y)
        )
    }

    private func drawText(
        _ ctx: CGContext,
        _ text: String,
        topLeft: CGPoint,
        size: CGFloat,
        color: CGColor
    ) {
        guard !text.isEmpty else { return }
        let font = makeFont(size)
        let ascent = CTFontGetAscent(font)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            kCTForegroundColorAttributeName as NSAttributedString.Key: color,
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attributed)
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: topLeft.x, y: topLeft.y + ascent)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    /// Paint the mosaic along the annotation's stroke. The whole image is
    /// block-averaged once (cached) and then clipped to the thick brush path,
    /// so the tool paints rather than dragging a rectangle.
    private func drawMosaic(
        _ ctx: CGContext,
        _ annotation: Annotation,
        imageRect: CGRect,
        image: (Int, Int)
    ) {
        guard let composed = session.composed, !annotation.points.isEmpty else { return }
        let block = mosaicBlock((composed.width, composed.height))
        let mosaic: CGImage
        if let cache = mosaicCache, cache.block == block {
            mosaic = cache.image
        } else if let made = Mosaic.make(composed, block: block) {
            mosaicCache = (block, made)
            mosaic = made
        } else {
            return
        }

        let scale = imageRect.width / CGFloat(max(composed.width, 1))
        let brush = max(annotation.stroke * scale, 6)
        let points = annotation.points.map { toScreen(imageRect, image, $0) }

        ctx.saveGState()
        ctx.beginPath()
        if points.count == 1 {
            let radius = brush / 2
            ctx.addEllipse(
                in: CGRect(x: points[0].x - radius, y: points[0].y - radius, width: brush, height: brush)
            )
        } else {
            ctx.move(to: points[0])
            for point in points.dropFirst() {
                ctx.addLine(to: point)
            }
            ctx.setLineWidth(brush)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.replacePathWithStrokedPath()
        }
        ctx.clip()

        // Draw the block-averaged image upright, with no smoothing for hard squares.
        ctx.interpolationQuality = .none
        ctx.translateBy(x: imageRect.minX, y: imageRect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(mosaic, in: CGRect(x: 0, y: 0, width: imageRect.width, height: imageRect.height))
        ctx.restoreGState()
    }

    /// A fresh draft for `tool`. The marker tools get a thick brush and the
    /// highlighter also gets a translucent colour instead of the plain stroke.
    private func makeDraft(tool: Tool, at start: CGPoint, image: (Int, Int)) -> Annotation {
        switch tool {
        case .highlighter:
            return Annotation(
                tool: tool,
                points: [start],
                color: Self.highlighterColor,
                stroke: defaultMarkerStroke(image),
                text: ""
            )
        case .mosaic:
            return Annotation(
                tool: tool,
                points: [start],
                color: state.color,
                stroke: defaultMarkerStroke(image),
                text: ""
            )
        default:
            return Annotation(
                tool: tool,
                points: [start],
                color: state.color,
                stroke: state.stroke,
                text: ""
            )
        }
    }

    /// Semi-transparent highlighter yellow.
    private static let highlighterColor: [CGFloat] = [1.0, 0.90, 0.20, 0.35]

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        commitText()
        let position = convert(event.locationInWindow, from: nil)
        let imageRect = state.imageRect
        let image = self.image
        guard image.0 > 0, imageRect.contains(position) else { return }
        let start = clampToImage(toImage(imageRect, image, position), image)
        if state.tool == .text {
            beginText(at: start)
            return
        }
        state.draft = makeDraft(tool: state.tool, at: start, image: image)
        dragging = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging, var draft = state.draft else { return }
        let point = clampToImage(
            toImage(state.imageRect, image, convert(event.locationInWindow, from: nil)),
            image
        )
        switch draft.tool {
        case .pen, .highlighter, .mosaic:
            draft.points.append(point)
        default:
            if draft.points.count < 2 {
                draft.points.append(point)
            } else {
                draft.points[1] = point
            }
        }
        state.draft = draft
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        dragging = false
        if let draft = state.draft, isRenderable(draft) {
            state.annotations.append(draft)
            state.redo.removeAll()
        }
        state.draft = nil
        needsDisplay = true
    }

    private func isRenderable(_ annotation: Annotation) -> Bool {
        guard annotation.points.count >= 2 else { return false }
        switch annotation.tool {
        case .pen, .highlighter, .mosaic:
            return true
        default:
            let a = annotation.points[0]
            let b = annotation.points[1]
            return abs(a.x - b.x) + abs(a.y - b.y) >= 2
        }
    }

    // MARK: - Text tool

    private func beginText(at position: CGPoint) {
        let imageRect = state.imageRect
        let image = self.image
        let size = max(state.textSize * imageRect.width / CGFloat(max(image.0, 1)), 8)
        let screen = toScreen(imageRect, image, position)
        let field = NSTextField(frame: CGRect(x: screen.x, y: screen.y, width: 240, height: size * 1.6))
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont.systemFont(ofSize: size)
        field.textColor = NSColor(
            srgbRed: state.color[0],
            green: state.color[1],
            blue: state.color[2],
            alpha: state.color[3]
        )
        field.delegate = self
        field.target = self
        field.action = #selector(commitText)
        addSubview(field)
        window?.makeFirstResponder(field)
        textField = field
        editingPosition = position
        needsDisplay = true
    }

    @objc private func commitText() {
        guard let field = textField, let position = editingPosition else { return }
        let text = field.stringValue
        textField = nil
        editingPosition = nil
        field.removeFromSuperview()
        if !text.isEmpty {
            state.annotations.append(
                Annotation(
                    tool: .text,
                    points: [position],
                    color: state.color,
                    stroke: state.textSize,
                    text: text
                )
            )
            state.redo.removeAll()
        }
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        commitText()
    }

    // MARK: - Export

    /// Rasterize the composed image and the annotations at native pixel size.
    func renderExport() -> Data? {
        guard let composed = session.composed else { return nil }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard
            let ctx = CGContext(
                data: nil,
                width: composed.width,
                height: composed.height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            return nil
        }
        // Make the context top-left, y-down to match `drawContent`.
        ctx.translateBy(x: 0, y: CGFloat(composed.height))
        ctx.scaleBy(x: 1, y: -1)
        let full = CGRect(x: 0, y: 0, width: CGFloat(composed.width), height: CGFloat(composed.height))
        drawContent(into: ctx, bounds: full, imageRect: full)
        guard let image = ctx.makeImage() else { return nil }
        return PNG.encode(image)
    }
}

/// A system font at `size`, bridged to Core Text.
func makeFont(_ size: CGFloat) -> CTFont {
    let name = NSFont.systemFont(ofSize: size).fontName
    return CTFontCreateWithName(name as CFString, size, nil)
}

/// The average RGB of a pixel rectangle in an RGBA8 image.
func averageRGB(_ source: [UInt8], w: Int, h: Int, rect: CGRect) -> (UInt8, UInt8, UInt8)? {
    let x0 = max(Int(rect.minX.rounded(.down)), 0)
    let y0 = max(Int(rect.minY.rounded(.down)), 0)
    let x1 = min(Int(rect.maxX.rounded(.up)), w)
    let y1 = min(Int(rect.maxY.rounded(.up)), h)
    guard x1 > x0, y1 > y0 else { return nil }
    var r = 0, g = 0, b = 0, n = 0
    for y in y0..<y1 {
        for x in x0..<x1 {
            let index = (y * w + x) * 4
            if index + 4 <= source.count {
                r += Int(source[index])
                g += Int(source[index + 1])
                b += Int(source[index + 2])
                n += 1
            }
        }
    }
    guard n > 0 else { return nil }
    return (UInt8(r / n), UInt8(g / n), UInt8(b / n))
}

/// Builds a block-averaged copy of an image: one output pixel per `block`×`block`
/// of source, later drawn with no interpolation to get hard mosaic squares.
enum Mosaic {
    static func make(_ composed: ComposedImage, block: Int) -> CGImage? {
        let w = composed.width
        let h = composed.height
        guard w > 0, h > 0, block > 0, composed.pixels.count >= w * h * 4 else { return nil }
        let cols = (w + block - 1) / block
        let rows = (h + block - 1) / block
        var buffer = [UInt8](repeating: 0, count: cols * rows * 4)
        for row in 0..<rows {
            for col in 0..<cols {
                let x0 = col * block
                let y0 = row * block
                let rect = CGRect(
                    x: x0,
                    y: y0,
                    width: min(x0 + block, w) - x0,
                    height: min(y0 + block, h) - y0
                )
                guard let rgb = averageRGB(composed.pixels, w: w, h: h, rect: rect) else { continue }
                let index = (row * cols + col) * 4
                buffer[index] = rgb.0
                buffer[index + 1] = rgb.1
                buffer[index + 2] = rgb.2
                buffer[index + 3] = 255
            }
        }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard
            let ctx = CGContext(
                data: &buffer,
                width: cols,
                height: rows,
                bitsPerComponent: 8,
                bytesPerRow: cols * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            return nil
        }
        return ctx.makeImage()
    }
}
