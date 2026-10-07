// The colour picker: sample a pixel from a frozen frame, show a magnifier and
// the hex value, and copy the value on click.

import AppKit
import CoreGraphics

enum ColorPicker {
    /// The colour of one pixel of `image` (sRGB), or nil when out of bounds.
    static func pixel(_ image: CGImage, x: Int, y: Int) -> NSColor? {
        guard x >= 0, y >= 0, x < image.width, y < image.height else { return nil }
        guard let sub = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else {
            return nil
        }
        var bytes = [UInt8](repeating: 0, count: 4)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        bytes.withUnsafeMutableBytes { buffer in
            guard
                let ctx = CGContext(
                    data: buffer.baseAddress,
                    width: 1,
                    height: 1,
                    bitsPerComponent: 8,
                    bytesPerRow: 4,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            else {
                return
            }
            ctx.draw(sub, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return NSColor(
            srgbRed: CGFloat(bytes[0]) / 255,
            green: CGFloat(bytes[1]) / 255,
            blue: CGFloat(bytes[2]) / 255,
            alpha: 1
        )
    }

    /// Draw the magnifier (a zoomed pixel grid with the centre cell marked) and
    /// the swatch + hex readout near `point`.
    static func drawMagnifier(
        _ ctx: CGContext,
        image: CGImage,
        at point: CGPoint,
        imageX: Int,
        imageY: Int,
        color: NSColor,
        viewport: CGRect
    ) {
        let grid = 11
        let half = grid / 2
        let width = image.width
        let height = image.height
        guard width >= grid, height >= grid else { return }
        let sx = max(0, min(imageX - half, width - grid))
        let sy = max(0, min(imageY - half, height - grid))
        guard let sub = image.cropping(to: CGRect(x: sx, y: sy, width: grid, height: grid)) else {
            return
        }

        let side: CGFloat = 110
        let infoHeight: CGFloat = 26
        var mx = point.x + 18
        var my = point.y + 18
        if mx + side > viewport.maxX { mx = point.x - side - 18 }
        if my + side + infoHeight + 6 > viewport.maxY { my = point.y - side - infoHeight - 6 }
        mx = max(viewport.minX + 4, mx)
        my = max(viewport.minY + 4, my)
        let magnifier = CGRect(x: mx, y: my, width: side, height: side)

        // The zoomed pixels (nearest, so the grid is crisp). Counter-flip for the
        // flipped view.
        ctx.saveGState()
        ctx.interpolationQuality = .none
        ctx.translateBy(x: magnifier.minX, y: magnifier.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(sub, in: CGRect(x: 0, y: 0, width: side, height: side))
        ctx.restoreGState()

        // Border and the centre cell.
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(magnifier)
        let cell = side / CGFloat(grid)
        let cx = magnifier.minX + CGFloat(imageX - sx) * cell
        let cy = magnifier.minY + CGFloat(imageY - sy) * cell
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.6).cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(CGRect(x: cx - 1, y: cy - 1, width: cell + 2, height: cell + 2))
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.stroke(CGRect(x: cx, y: cy, width: cell, height: cell))

        // Swatch + hex below the magnifier.
        let infoY = magnifier.maxY + 6
        let swatch = CGRect(x: magnifier.minX, y: infoY, width: infoHeight, height: infoHeight)
        ctx.setFillColor(color.cgColor)
        ctx.fill(swatch)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.5).cgColor)
        ctx.stroke(swatch)

        let hex = color.hexString
        let attributed = NSAttributedString(
            string: hex,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor.white,
            ]
        )
        let textSize = attributed.size()
        let box = CGRect(
            x: swatch.maxX + 6,
            y: infoY,
            width: textSize.width + 12,
            height: infoHeight
        )
        ctx.setFillColor(NSColor(calibratedWhite: 0, alpha: 0.78).cgColor)
        ctx.fill(box)
        attributed.draw(
            at: CGPoint(x: box.minX + 6, y: box.minY + (infoHeight - textSize.height) / 2)
        )
    }
}

extension NSColor {
    /// `#RRGGBB` in sRGB.
    var hexString: String {
        let color = usingColorSpace(.sRGB) ?? self
        let red = Int((color.redComponent * 255).rounded())
        let green = Int((color.greenComponent * 255).rounded())
        let blue = Int((color.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}
