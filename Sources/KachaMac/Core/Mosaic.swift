// Block-averaged mosaic source and the pixel sampling it needs.
//
// The mosaic tool paints by clipping a thick brush path and drawing this
// block-averaged copy with no interpolation, so it reads as hard squares.

import CoreGraphics

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
