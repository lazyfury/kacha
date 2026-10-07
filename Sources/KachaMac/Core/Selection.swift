// Region-selection geometry and drag state — pure, unit-testable.
//
// All coordinates are **global logical points** (origin top-left, the
// CoreGraphics global space). A display's overlay converts to local by
// subtracting its origin.

import CoreGraphics

enum Selection {
    /// The eight resize handles, named by compass direction.
    enum Handle: CaseIterable {
        case nw, n, ne, e, se, s, sw, w
    }

    /// What a pointer drag is currently doing.
    enum Drag: Equatable {
        case none
        case new(anchor: CGPoint)
        case move(grab: CGPoint, start: CGRect)
        case resize(handle: Handle, start: CGRect)
    }

    /// Drawn size of a handle, in logical points.
    static let handleSize: CGFloat = 8
    /// Half-extent of a handle's hit area; a little larger than the drawn square.
    static let handleHit: CGFloat = 5
    /// A selection smaller than this is treated as a stray click, not a region.
    static let minSize: CGFloat = 4

    /// Begin a drag at global point `p`, given the current selection. Returns the
    /// drag to remember and the selection to store now.
    static func begin(current: CGRect?, at p: CGPoint) -> (Drag, CGRect?) {
        if let rect = current {
            if let handle = handleAt(rect, p) {
                return (.resize(handle: handle, start: rect), rect)
            }
            if rect.contains(p) {
                return (.move(grab: p, start: rect), rect)
            }
        }
        return (.new(anchor: p), CGRect(origin: p, size: .zero))
    }

    /// Advance a drag to global point `p`.
    static func update(_ drag: Drag, to p: CGPoint, current: CGRect?) -> CGRect? {
        switch drag {
        case .none:
            return current
        case .new(let anchor):
            return rectBetween(anchor, p)
        case .move(let grab, let start):
            return start.offsetBy(dx: p.x - grab.x, dy: p.y - grab.y)
        case .resize(let handle, let start):
            return resize(start, handle: handle, to: p)
        }
    }

    /// Finish a drag. A new selection that never grew past `minSize` is cleared.
    static func finish(_ drag: Drag, current: CGRect?) -> CGRect? {
        if case .new = drag {
            return current.flatMap { usable($0) ? $0 : nil }
        }
        return current
    }

    /// Whether `rect` is large enough to keep / confirm.
    static func usable(_ rect: CGRect) -> Bool {
        rect.width >= minSize && rect.height >= minSize
    }

    /// The handle under global point `p`, if any.
    static func handleAt(_ rect: CGRect, _ p: CGPoint) -> Handle? {
        for (handle, center) in handleCenters(rect) {
            if abs(p.x - center.x) <= handleHit && abs(p.y - center.y) <= handleHit {
                return handle
            }
        }
        return nil
    }

    /// The handle centres of `rect`, for drawing and hit-testing.
    static func handleCenters(_ rect: CGRect) -> [(Handle, CGPoint)] {
        let mid = CGPoint(x: rect.midX, y: rect.midY)
        return [
            (.nw, CGPoint(x: rect.minX, y: rect.minY)),
            (.n, CGPoint(x: mid.x, y: rect.minY)),
            (.ne, CGPoint(x: rect.maxX, y: rect.minY)),
            (.e, CGPoint(x: rect.maxX, y: mid.y)),
            (.se, CGPoint(x: rect.maxX, y: rect.maxY)),
            (.s, CGPoint(x: mid.x, y: rect.maxY)),
            (.sw, CGPoint(x: rect.minX, y: rect.maxY)),
            (.w, CGPoint(x: rect.minX, y: mid.y)),
        ]
    }

    /// The rectangle between two corners (order-independent).
    static func rectBetween(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(a.x - b.x),
            height: abs(a.y - b.y)
        )
    }

    /// Resize `start` by moving `handle` to global point `p`.
    static func resize(_ start: CGRect, handle: Handle, to p: CGPoint) -> CGRect {
        var x0 = start.minX
        var y0 = start.minY
        var x1 = start.maxX
        var y1 = start.maxY
        switch handle {
        case .nw: x0 = p.x; y0 = p.y
        case .n: y0 = p.y
        case .ne: x1 = p.x; y0 = p.y
        case .e: x1 = p.x
        case .se: x1 = p.x; y1 = p.y
        case .s: y1 = p.y
        case .sw: x0 = p.x; y1 = p.y
        case .w: x0 = p.x
        }
        return rectBetween(CGPoint(x: x0, y: y0), CGPoint(x: x1, y: y1))
    }

    /// Global logical rectangle → a display's local coordinates.
    static func toLocal(_ global: CGRect, origin: CGPoint) -> CGRect {
        global.offsetBy(dx: -origin.x, dy: -origin.y)
    }

    /// The four dim-wash rectangles around `selection` within `viewport`. With no
    /// selection the whole viewport is returned as one rectangle.
    static func maskRects(viewport: CGRect, selection: CGRect?) -> [CGRect] {
        guard let selection, let hole = intersection(selection, viewport) else {
            return [viewport]
        }
        return [
            // above
            CGRect(x: viewport.minX, y: viewport.minY, width: viewport.width, height: hole.minY - viewport.minY),
            // below
            CGRect(x: viewport.minX, y: hole.maxY, width: viewport.width, height: viewport.maxY - hole.maxY),
            // left
            CGRect(x: viewport.minX, y: hole.minY, width: hole.minX - viewport.minX, height: hole.height),
            // right
            CGRect(x: hole.maxX, y: hole.minY, width: viewport.maxX - hole.maxX, height: hole.height),
        ]
    }

    /// `a ∩ b`, or nil when they do not overlap (CGRect.intersection returns a
    /// null rect instead of nil).
    static func intersection(_ a: CGRect, _ b: CGRect) -> CGRect? {
        let r = a.intersection(b)
        return r.isNull || r.isEmpty ? nil : r
    }
}
