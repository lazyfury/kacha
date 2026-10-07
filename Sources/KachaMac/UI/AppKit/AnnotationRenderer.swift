// Rasterizes the composed image and its annotations into a top-left, y-down
// `CGContext`. The same routine backs the on-screen preview and the
// native-pixel export, so they match exactly.
//
// The renderer owns the mosaic cache (the block-averaged image), so one instance
// per canvas avoids rebuilding it on every repaint.

import AppKit
import CoreGraphics
import CoreText

@MainActor
final class AnnotationRenderer {
    /// Block-averaged copy of the composed image, built once for the mosaic tool.
    private var mosaicCache: (block: Int, image: CGImage)?
    /// System fonts cached per size — the canvas redraws the same sizes.
    private var fonts: [CGFloat: CTFont] = [:]

    /// A system font at `size`, bridged to Core Text. Cached so a repaint does
    /// not rebuild a `CTFont` for every annotation.
    func font(_ size: CGFloat) -> CTFont {
        if let cached = fonts[size] { return cached }
        let name = NSFont.systemFont(ofSize: size).fontName
        let created = CTFontCreateWithName(name as CFString, size, nil)
        fonts[size] = created
        return created
    }

    /// Draw the composed image and the annotations into `ctx` (assumed to be a
    /// top-left, y-down context). `imageRect` is where the image is drawn.
    /// `skipIndex` hides the annotation currently being re-edited.
    func drawContent(
        into ctx: CGContext,
        bounds: CGRect,
        imageRect: CGRect,
        composed: ComposedImage,
        annotations: [Annotation],
        draft: Annotation?,
        skipIndex: Int?
    ) {
        ctx.setFillColor(NSColor(calibratedWhite: 0.08, alpha: 1).cgColor)
        ctx.fill(bounds)
        drawImage(ctx, composed.image, in: imageRect)
        let image = (composed.width, composed.height)
        for (index, annotation) in annotations.enumerated() where index != skipIndex {
            drawAnnotation(
                ctx,
                annotation,
                imageRect: imageRect,
                image: image,
                composed: composed
            )
        }
        if let draft {
            drawAnnotation(ctx, draft, imageRect: imageRect, image: image, composed: composed)
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

    private func drawAnnotation(
        _ ctx: CGContext,
        _ annotation: Annotation,
        imageRect: CGRect,
        image: (Int, Int),
        composed: ComposedImage
    ) {
        let color = annotation.color
        let cgColor = CGColor(srgbRed: color[0], green: color[1], blue: color[2], alpha: color[3])
        let scale = imageRect.width / CGFloat(max(image.0, 1))
        let width = max(annotation.stroke * scale, 1)
        let points = annotation.points.map { toScreen(imageRect, image, $0) }

        switch annotation.tool {
        case .rectangle:
            if let rect = rectFrom(points) {
                if annotation.filled {
                    ctx.setFillColor(
                        CGColor(srgbRed: color[0], green: color[1], blue: color[2], alpha: 0.35)
                    )
                    ctx.fill(rect)
                }
                ctx.setStrokeColor(cgColor)
                ctx.setLineWidth(width)
                ctx.stroke(rect)
            }
        case .ellipse:
            if let rect = rectFrom(points) {
                if annotation.filled {
                    ctx.setFillColor(
                        CGColor(srgbRed: color[0], green: color[1], blue: color[2], alpha: 0.35)
                    )
                    ctx.fillEllipse(in: rect)
                }
                ctx.setStrokeColor(cgColor)
                ctx.setLineWidth(width)
                ctx.strokeEllipse(in: rect)
            }
        case .line:
            if let a = points.first, let b = points.dropFirst().first {
                ctx.setStrokeColor(cgColor)
                ctx.setLineWidth(width)
                ctx.setLineCap(.round)
                ctx.beginPath()
                ctx.move(to: a)
                ctx.addLine(to: b)
                ctx.strokePath()
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
                drawText(
                    ctx,
                    annotation.text,
                    topLeft: position,
                    size: max(annotation.stroke * scale, 8),
                    color: cgColor
                )
            }
        case .number:
            if let center = points.first {
                drawNumber(
                    ctx,
                    annotation.text,
                    center: center,
                    size: max(annotation.stroke * scale, 10),
                    rgba: color
                )
            }
        case .mosaic:
            drawMosaic(ctx, annotation, imageRect: imageRect, image: image, composed: composed)
        }
    }

    /// A numbered marker: a filled disc in the annotation colour with the number
    /// centred on top (black or white, whichever contrasts with the fill).
    private func drawNumber(
        _ ctx: CGContext,
        _ text: String,
        center: CGPoint,
        size: CGFloat,
        rgba: [CGFloat]
    ) {
        guard !text.isEmpty else { return }
        let radius = size * 0.9
        let disc = CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        ctx.setFillColor(CGColor(srgbRed: rgba[0], green: rgba[1], blue: rgba[2], alpha: rgba[3]))
        ctx.fillEllipse(in: disc)

        let luminance = 0.2126 * rgba[0] + 0.7152 * rgba[1] + 0.0722 * rgba[2]
        let textColor: CGColor = luminance > 0.6
            ? CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
            : CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        let font = font(size)
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                kCTForegroundColorAttributeName as NSAttributedString.Key: textColor,
            ]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        let textSize = attributed.size()
        let ascent = CTFontGetAscent(font)
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(
            x: center.x - textSize.width / 2,
            y: center.y - textSize.height / 2 + ascent
        )
        CTLineDraw(line, ctx)
        ctx.restoreGState()
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
        let font = font(size)
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
        image: (Int, Int),
        composed: ComposedImage
    ) {
        guard !annotation.points.isEmpty else { return }
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
}
