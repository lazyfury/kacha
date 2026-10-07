// A small centred countdown shown before a delayed capture.
//
// The panel is owned by the app, so ScreenCaptureKit excludes it from the frozen
// frame. It never takes focus (`nonactivatingPanel`, `ignoresMouseEvents`), so
// the user can keep arranging the screen while it runs.

import AppKit

@MainActor
final class CountdownHUD {
    private var panel: NSPanel?
    private var view: CountdownView?
    private var timer: Timer?
    private var remaining = 0
    private var onFinish: (() -> Void)?

    /// Count down from `seconds`, then run `onFinish` on the main actor. Zero or
    /// less finishes immediately, so the caller needs no special case.
    func start(seconds: Int, onFinish: @escaping () -> Void) {
        cancel()
        guard seconds > 0 else {
            onFinish()
            return
        }
        self.onFinish = onFinish
        remaining = seconds

        let side: CGFloat = 96
        let view = CountdownView(number: seconds)
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
        let origin = screen.map { screen in
            CGPoint(x: screen.frame.midX - side / 2, y: screen.frame.midY - side / 2)
        } ?? .zero

        let panel = NSPanel(
            contentRect: CGRect(origin: origin, size: CGSize(width: side, height: side)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        WindowChrome.own(panel)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        // Never let the countdown leak into a capture of our own overlay.
        panel.sharingType = .none
        panel.contentView = view
        panel.orderFrontRegardless()

        self.view = view
        self.panel = panel

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            // The timer is scheduled on the main run loop, so this is the main actor.
            MainActor.assumeIsolated {
                self?.tick(timer)
            }
        }
    }

    private func tick(_ timer: Timer) {
        remaining -= 1
        view?.number = remaining
        view?.needsDisplay = true
        if remaining <= 0 {
            timer.invalidate()
            let finish = onFinish
            cancel()
            finish?()
        }
    }

    /// Stop the countdown without running the completion.
    func cancel() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil
        view = nil
        onFinish = nil
        remaining = 0
    }
}

/// The countdown disc: a translucent dark circle with a big white number.
private final class CountdownView: NSView {
    var number: Int

    init(number: Int) {
        self.number = number
        super.init(frame: NSRect(x: 0, y: 0, width: 96, height: 96))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("CountdownView is created programmatically") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let disc = bounds.insetBy(dx: 2, dy: 2)
        ctx.setFillColor(NSColor(calibratedWhite: 0.08, alpha: 0.72).cgColor)
        ctx.fillEllipse(in: disc)
        ctx.setStrokeColor(NSColor(calibratedWhite: 1, alpha: 0.25).cgColor)
        ctx.setLineWidth(1)
        ctx.strokeEllipse(in: disc)

        let text = NSAttributedString(
            string: "\(number)",
            attributes: [
                .font: NSFont.systemFont(ofSize: 44, weight: .semibold),
                .foregroundColor: NSColor.white,
            ]
        )
        let size = text.size()
        text.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }
}
