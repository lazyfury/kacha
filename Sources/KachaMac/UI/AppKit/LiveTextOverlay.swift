// In-place Live Text selection over the editor canvas (VisionKit).
//
// Mirrors the iPhone Photos behaviour: the system `ImageAnalysisOverlayView`
// lets the user drag-select recognized text on the image and copy it from the
// context menu. The overlay sits on an `NSImageView` aligned to the drawn image,
// added on top of the AppKit canvas.

import AppKit
import VisionKit

@MainActor
final class LiveTextOverlay: NSView {
    private let sourceImage: CGImage
    private let imageView = NSImageView()
    private let overlayView: ImageAnalysisOverlayView

    /// Called with the full transcript when the user asks to show all the text.
    var onShowAll: ((String) -> Void)?

    init(image: CGImage) {
        sourceImage = image
        overlayView = ImageAnalysisOverlayView(frame: .zero)
        super.init(frame: .zero)
        imageView.image = NSImage(cgImage: image, size: .zero)
        imageView.imageScaling = .scaleAxesIndependently
        addSubview(imageView)

        overlayView.trackingImageView = imageView
        overlayView.preferredInteractionTypes = .textSelection
        overlayView.delegate = self
        imageView.addSubview(overlayView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("LiveTextOverlay is created programmatically") }

    override func layout() {
        super.layout()
        imageView.frame = bounds
        overlayView.frame = imageView.bounds
    }

    /// Analyze the image and attach the result to the overlay. Runs off the
    /// main thread; `overlayView.analysis` is set back on the main actor.
    func analyze() async {
        guard let analysis = await OCR.analyze(sourceImage) else { return }
        overlayView.analysis = analysis
    }
}

extension LiveTextOverlay: ImageAnalysisOverlayViewDelegate {
    func overlayView(
        _ overlayView: ImageAnalysisOverlayView,
        updatedMenuFor menu: NSMenu,
        for event: NSEvent,
        at point: CGPoint
    ) -> NSMenu {
        menu.addItem(.separator())
        let copyAll = NSMenuItem(
            title: "复制全部文字",
            action: #selector(copyAllText),
            keyEquivalent: ""
        )
        copyAll.target = self
        menu.addItem(copyAll)
        let showAll = NSMenuItem(
            title: "显示全部文字…",
            action: #selector(showAllText),
            keyEquivalent: ""
        )
        showAll.target = self
        menu.addItem(showAll)
        return menu
    }

    @objc private func copyAllText() {
        Export.copyString(overlayView.text)
    }

    @objc private func showAllText() {
        onShowAll?(overlayView.text)
    }
}
