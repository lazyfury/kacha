// Editor geometry and size heuristics — pure, unit-testable (no windows).
//
// Image coordinates are **image pixels**; view coordinates are points in the
// canvas's top-left, y-down space. The canvas that uses these lives in the
// AppKit layer.

import CoreGraphics

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
