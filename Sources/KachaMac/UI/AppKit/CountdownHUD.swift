// A small centred countdown shown before a delayed capture or a recording.
//
// The panel is owned by the app, so ScreenCaptureKit excludes it from the frozen
// frame. It never takes focus, and stays click-through unless it carries a
// microphone toggle.

import AppKit
import SwiftUI

@MainActor
final class CountdownHUD {
    private var panel: NSPanel?
    private var timer: Timer?
    private let model = CountdownModel()
    private var remaining = 0
    private var onFinish: (() -> Void)?
    private var onToggleMic: (() -> Void)?

    /// Count down from `seconds`, then run `onFinish` on the main actor. Zero or
    /// less finishes immediately, so the caller needs no special case. When
    /// `micAvailable`, a microphone toggle is shown and clicks are accepted.
    func start(
        seconds: Int,
        micAvailable: Bool = false,
        micMuted: Bool = false,
        onToggleMic: (() -> Void)? = nil,
        onFinish: @escaping () -> Void
    ) {
        cancel()
        guard seconds > 0 else {
            onFinish()
            return
        }
        self.onFinish = onFinish
        self.onToggleMic = onToggleMic
        remaining = seconds
        model.number = seconds
        model.micMuted = micMuted

        let root = CountdownView(
            model: model,
            micAvailable: micAvailable,
            onToggleMic: { [weak self] in self?.onToggleMic?() }
        )
        let hosting = NSHostingController(rootView: root)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 96, height: micAvailable ? 140 : 96),
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
        panel.animationBehavior = .none
        // Never let the countdown leak into a capture of our own overlay.
        panel.sharingType = .none
        // The microphone toggle needs clicks; otherwise stay out of the way.
        panel.ignoresMouseEvents = !micAvailable
        panel.contentView = hosting.view
        hosting.view.layoutSubtreeIfNeeded()
        panel.setContentSize(hosting.view.fittingSize)
        position(panel)
        panel.orderFrontRegardless()
        self.panel = panel

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            // The timer runs on the main run loop, so this is the main actor.
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
    }

    /// Reflect the microphone's mute state on the toggle.
    func setMicMuted(_ muted: Bool) {
        model.micMuted = muted
    }

    private func tick() {
        remaining -= 1
        model.number = max(remaining, 0)
        if remaining <= 0 {
            timer?.invalidate()
            timer = nil
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
        onFinish = nil
        onToggleMic = nil
        remaining = 0
    }

    /// Centre of the display under the cursor.
    private func position(_ panel: NSPanel) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
        guard let screen else {
            panel.center()
            return
        }
        let frame = screen.frame
        let size = panel.frame.size
        panel.setFrameOrigin(
            CGPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2)
        )
    }
}
