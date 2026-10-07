// The editor's shared state. `ObservableObject` so the SwiftUI toolbar reacts
// to the active tool and to undo / redo availability.

import Combine
import CoreGraphics

@MainActor
final class EditorState: ObservableObject {
    @Published var tool: Tool = .rectangle
    /// RGBA in 0...1.
    @Published var color: [CGFloat] = AnnotationPalette.colors[0].rgba
    /// Stroke width as a multiple of `defaultStroke(image)`.
    @Published var strokeFactor: CGFloat = 1
    /// Whether the rectangle tool fills its shape.
    @Published var rectangleFilled = false
    /// Font size in image pixels, for the text tool.
    var textSize: CGFloat = 18
    @Published var annotations: [Annotation] = []
    @Published var redo: [Annotation] = []
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
