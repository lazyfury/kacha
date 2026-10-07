// The editor canvas: turns mouse input into annotations and hosts the inline
// text field. Drawing and image/point mapping live in `AnnotationRenderer` and
// `EditorGeometry`.
//
// All annotation coordinates are in **image pixels**; the canvas letterboxes the
// image and records its on-screen rect in `state.imageRect`.

import AppKit
import CoreGraphics

/// The canvas: composed image + annotations, with the editor's mouse handling.
final class EditorCanvasView: NSView, NSTextFieldDelegate {
    let session: CaptureSession
    let state: EditorState

    /// Called when Live Text asks to show the full recognized transcript.
    var onShowAllText: ((String) -> Void)?

    private let renderer = AnnotationRenderer()
    private var liveText: LiveTextOverlay?
    private var dragging = false
    private var textField: NSTextField?
    private var editingPosition: CGPoint?
    /// The index of the text annotation being re-edited, if any.
    private var editingAnnotation: Int?

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
        let imageRect = containFit(image, in: bounds) ?? .zero
        state.imageRect = imageRect
        liveText?.frame = imageRect
        drawContent(into: ctx, bounds: bounds, imageRect: imageRect)
    }

    /// Draw the composed image and the annotations into `ctx` (assumed to be a
    /// top-left, y-down context). `imageRect` is where the image is drawn.
    func drawContent(into ctx: CGContext, bounds: CGRect, imageRect: CGRect) {
        guard let composed = session.composed else {
            ctx.setFillColor(NSColor(calibratedWhite: 0.08, alpha: 1).cgColor)
            ctx.fill(bounds)
            return
        }
        renderer.drawContent(
            into: ctx,
            bounds: bounds,
            imageRect: imageRect,
            composed: composed,
            annotations: state.annotations,
            draft: state.draft,
            skipIndex: editingAnnotation
        )
    }

    // MARK: - Drafts

    /// A fresh draft for `tool`. The marker tools get a thick brush and the
    /// highlighter also gets a translucent colour instead of the plain stroke.
    private func makeDraft(tool: Tool, at start: CGPoint, image: (Int, Int)) -> Annotation {
        let stroke = defaultStroke(image) * state.strokeFactor
        let marker = max(defaultMarkerStroke(image) * state.strokeFactor, 16)
        switch tool {
        case .highlighter:
            return Annotation(
                tool: tool,
                points: [start],
                color: AnnotationPalette.translucent(state.color, alpha: 0.35),
                stroke: marker,
                text: ""
            )
        case .mosaic:
            return Annotation(
                tool: tool,
                points: [start],
                color: state.color,
                stroke: marker,
                text: ""
            )
        case .rectangle:
            return Annotation(
                tool: tool,
                points: [start],
                color: state.color,
                stroke: stroke,
                text: "",
                filled: state.rectangleFilled
            )
        default:
            return Annotation(
                tool: tool,
                points: [start],
                color: state.color,
                stroke: stroke,
                text: ""
            )
        }
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        guard liveText == nil else { return }
        commitText()
        let position = convert(event.locationInWindow, from: nil)
        let imageRect = state.imageRect
        let image = self.image
        guard image.0 > 0, imageRect.contains(position) else { return }
        let start = clampToImage(toImage(imageRect, image, position), image)
        if event.clickCount == 2, let index = textAnnotationIndex(at: start) {
            beginText(at: state.annotations[index].points[0], editing: index)
            return
        }
        if state.tool == .text {
            if let index = textAnnotationIndex(at: start) {
                beginText(at: state.annotations[index].points[0], editing: index)
            } else {
                beginText(at: start, editing: nil)
            }
            return
        }
        state.draft = makeDraft(tool: state.tool, at: start, image: image)
        dragging = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard liveText == nil, dragging, var draft = state.draft else { return }
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
        guard liveText == nil, dragging else { return }
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

    /// The index of the topmost text annotation whose box contains `point`.
    private func textAnnotationIndex(at point: CGPoint) -> Int? {
        for index in state.annotations.indices.reversed() {
            let annotation = state.annotations[index]
            guard annotation.tool == .text, let bounds = textBounds(annotation) else { continue }
            if bounds.insetBy(dx: -4, dy: -4).contains(point) {
                return index
            }
        }
        return nil
    }

    /// The rendered box of a text annotation, in image pixels.
    private func textBounds(_ annotation: Annotation) -> CGRect? {
        guard let origin = annotation.points.first, !annotation.text.isEmpty else { return nil }
        let size = NSAttributedString(
            string: annotation.text,
            attributes: [.font: renderer.font(annotation.stroke)]
        ).size()
        return CGRect(origin: origin, size: size)
    }

    private func beginText(at position: CGPoint, editing: Int?) {
        let imageRect = state.imageRect
        let image = self.image
        let existing = editing.map { state.annotations[$0] }
        let fontSize = existing?.stroke ?? state.textSize
        let color = existing?.color ?? state.color
        let size = max(fontSize * imageRect.width / CGFloat(max(image.0, 1)), 8)
        let screen = toScreen(imageRect, image, position)
        let field = NSTextField(
            frame: CGRect(x: screen.x, y: screen.y, width: 240, height: size * 1.6)
        )
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont.systemFont(ofSize: size)
        field.textColor = NSColor(
            srgbRed: color[0],
            green: color[1],
            blue: color[2],
            alpha: color[3]
        )
        field.stringValue = existing?.text ?? ""
        field.delegate = self
        field.target = self
        field.action = #selector(commitText)
        addSubview(field)
        window?.makeFirstResponder(field)
        textField = field
        editingPosition = position
        editingAnnotation = editing
        needsDisplay = true
    }

    @objc private func commitText() {
        guard let field = textField, let position = editingPosition else { return }
        let text = field.stringValue
        let editing = editingAnnotation
        textField = nil
        editingPosition = nil
        editingAnnotation = nil
        field.removeFromSuperview()
        if let editing {
            if text.isEmpty {
                state.annotations.remove(at: editing)
            } else {
                state.annotations[editing].text = text
            }
            state.redo.removeAll()
        } else if !text.isEmpty {
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

    // MARK: - Live Text

    /// Toggle in-place text selection over the drawn image.
    func toggleLiveText() {
        setLiveText(active: liveText == nil)
    }

    private func setLiveText(active: Bool) {
        if active {
            guard liveText == nil, let composed = session.composed else { return }
            let overlay = LiveTextOverlay(image: composed.image)
            overlay.onShowAll = { [weak self] text in self?.onShowAllText?(text) }
            overlay.frame = state.imageRect
            addSubview(overlay)
            liveText = overlay
            Task { await overlay.analyze() }
        } else {
            liveText?.removeFromSuperview()
            liveText = nil
        }
        state.liveTextActive = liveText != nil
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if liveText != nil, event.keyCode == 53 {  // Escape exits text selection
            setLiveText(active: false)
            return
        }
        super.keyDown(with: event)
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
