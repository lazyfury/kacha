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
    static let fillOff = "square"
    static let fillOn = "square.fill"
    static let selectText = "text.viewfinder"

    /// Every symbol the toolbar may show (the self-check resolves them all).
    static var all: [String] {
        Tool.allCases.map(\.symbol)
            + [undo, redo, copy, save, pin, close, fillOff, fillOn, selectText]
    }
}

/// A named annotation colour (RGBA in 0...1).
struct AnnotationColor: Hashable {
    let name: String
    let rgba: [CGFloat]
}

/// The toolbar's colour and stroke-width choices.
enum AnnotationPalette {
    static let colors: [AnnotationColor] = [
        AnnotationColor(name: "红", rgba: [1, 0.2, 0.2, 1]),
        AnnotationColor(name: "橙", rgba: [1, 0.58, 0, 1]),
        AnnotationColor(name: "黄", rgba: [1, 0.8, 0, 1]),
        AnnotationColor(name: "绿", rgba: [0.2, 0.78, 0.35, 1]),
        AnnotationColor(name: "蓝", rgba: [0.16, 0.55, 1, 1]),
        AnnotationColor(name: "紫", rgba: [0.6, 0.35, 0.9, 1]),
        AnnotationColor(name: "黑", rgba: [0, 0, 0, 1]),
        AnnotationColor(name: "白", rgba: [1, 1, 1, 1]),
    ]

    /// Stroke width as a multiple of the image's default stroke.
    static let strokePresets: [(name: String, factor: CGFloat)] = [
        ("细", 0.5), ("标准", 1), ("粗", 2), ("特粗", 3),
    ]

    /// A translucent version of `rgba` (fills / highlighter).
    static func translucent(_ rgba: [CGFloat], alpha: CGFloat) -> [CGFloat] {
        [rgba[0], rgba[1], rgba[2], alpha]
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
    /// Whether the rectangle tool fills its shape (ignored by other tools).
    var filled = false

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
