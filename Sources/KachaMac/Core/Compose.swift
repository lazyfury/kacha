// Compose the confirmed selection into one image at native pixel scale.
//
// The frozen frames are per display; a selection can span displays (or part of
// one). Each display's image is drawn into an output context at the anchor
// display's scale, so a Retina region comes out at full resolution. The result
// keeps a CGImage (for drawing); the RGBA8 pixel copy for mosaic sampling is
// rasterized only when the mosaic tool first asks for it.

import CoreGraphics

/// A composed capture: the renderable image plus its geometry. The tight RGBA8
/// copy (used only by the mosaic tool) is built on first access and cached, so
/// the common capture path never pays for the extra full-size buffer.
final class ComposedImage {
    let image: CGImage
    let width: Int
    let height: Int

    private var cachedPixels: [UInt8]?

    init(image: CGImage, width: Int, height: Int) {
        self.image = image
        self.width = width
        self.height = height
    }

    /// Tightly packed RGBA8, for the mosaic tool.
    var pixels: [UInt8] {
        if let cachedPixels { return cachedPixels }
        let made = Self.rasterize(image)
        cachedPixels = made
        return made
    }

    /// Draw `image` into a tightly packed premultiplied-RGBA8 buffer.
    private static func rasterize(_ image: CGImage) -> [UInt8] {
        let w = image.width
        let h = image.height
        guard w > 0, h > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        buffer.withUnsafeMutableBytes { raw in
            guard
                let ctx = CGContext(
                    data: raw.baseAddress,
                    width: w,
                    height: h,
                    bitsPerComponent: 8,
                    bytesPerRow: w * 4,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            else {
                return
            }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return buffer
    }
}

enum Compose {
    /// Crop `selection` (global logical points) out of `displays`. Returns nil
    /// when the selection is unusable or no display intersects it.
    static func compose(_ displays: [CapturedDisplay], selection: CGRect) -> ComposedImage? {
        guard Selection.usable(selection) else { return nil }

        // The output scale follows the display under the selection's top-left, so
        // the common case is an exact 1:1 copy. A mixed-DPI span falls back to
        // the largest display scale.
        let anchor = CGPoint(x: selection.minX, y: selection.minY)
        let scale = displays.first { $0.globalRect.contains(anchor) }?.scale
            ?? displays.map(\.scale).max()
            ?? 1

        let outW = max(Int((selection.width * scale).rounded()), 1)
        let outH = max(Int((selection.height * scale).rounded()), 1)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard
            let ctx = CGContext(
                data: nil,
                width: outW,
                height: outH,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            return nil
        }
        ctx.interpolationQuality = .high

        var any = false
        for display in displays {
            guard Selection.intersection(selection, display.globalRect) != nil else {
                continue
            }
            any = true
            // Draw the whole display image (the context clips it to the
            // selection); map its logical origin into output pixels.
            let dx = (display.origin.x - selection.minX) * scale
            let dy = (display.origin.y - selection.minY) * scale
            let dw = display.logicalSize.width * scale
            let dh = display.logicalSize.height * scale
            // CGContext is y-up; our logical space is y-down.
            let rect = CGRect(x: dx, y: CGFloat(outH) - dy - dh, width: dw, height: dh)
            ctx.draw(display.image, in: rect)
        }
        guard any, let image = ctx.makeImage() else { return nil }
        return ComposedImage(image: image, width: outW, height: outH)
    }

    /// Wrap an already-rendered image (a captured window) as a composed image.
    static func composed(from image: CGImage) -> ComposedImage? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
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
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let rendered = ctx.makeImage() else { return nil }
        return ComposedImage(image: rendered, width: width, height: height)
    }
}
