// The annotation model: what the editor can draw on top of the capture.
//
// Pure data, in **image pixel** coordinates (origin top-left), so it survives
// the canvas letterbox and the native-pixel export.

import CoreGraphics

/// The tools the editor toolbar offers.
enum Tool: CaseIterable {
    case rectangle
    case arrow
    case pen
    case highlighter
    case text
    case mosaic

    var label: String {
        switch self {
        case .rectangle: return "矩形"
        case .arrow: return "箭头"
        case .pen: return "画笔"
        case .highlighter: return "高亮"
        case .text: return "文字"
        case .mosaic: return "马赛克"
        }
    }

    /// The SF Symbol shown on the toolbar (falls back to `label` if missing).
    var symbol: String {
        switch self {
        case .rectangle: return "rectangle"
        case .arrow: return "arrow.up.right"
        case .pen: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .text: return "textformat"
        case .mosaic: return "squareshape.split.3x3"
        }
    }

    /// Show the Chinese label instead of the SF Symbol (the symbol reads poorly).
    var showsTextOnly: Bool { self == .text }
}

/// SF Symbols used by the editor toolbar.
enum ToolbarSymbol {
    static let undo = "arrow.uturn.backward"
    static let redo = "arrow.uturn.forward"
    static let copy = "doc.on.doc"
    static let save = "square.and.arrow.down"
    static let pin = "pin"
    static let close = "xmark"

    /// Every symbol the toolbar may show (the self-check resolves them all).
    static var all: [String] {
        Tool.allCases.map(\.symbol) + [undo, redo, copy, save, pin, close]
    }
}

/// One annotation in image pixel coordinates.
struct Annotation: Equatable {
    var tool: Tool
    /// The points that define the shape: a rect two corners, a pen/highlighter/
    /// mosaic a polyline, an arrow start/end, text an origin.
    var points: [CGPoint]
    /// RGBA in 0...1.
    var color: [CGFloat]
    /// Stroke width (or font size for text) in image pixels.
    var stroke: CGFloat
    var text: String

    static func between(_ tool: Tool, _ from: CGPoint, _ to: CGPoint) -> Annotation {
        Annotation(tool: tool, points: [from, to], color: [1, 0.2, 0.2, 1], stroke: 2, text: "")
    }

    /// The axis-aligned bounds of the annotation's points, if any.
    func bounds() -> CGRect? {
        guard let first = points.first else { return nil }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for p in points.dropFirst() {
            minX = min(minX, p.x); minY = min(minY, p.y)
            maxX = max(maxX, p.x); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
