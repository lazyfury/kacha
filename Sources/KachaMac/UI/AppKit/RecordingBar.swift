// The floating recording control bar: a small always-on-top panel with the
// timer and stop / cancel. It is excluded from the capture (`sharingType = .none`)
// so it never lands in the recording.

import AppKit
import SwiftUI

@MainActor
final class RecordingBarModel: ObservableObject {
    @Published var elapsed: TimeInterval = 0
    @Published var micMuted = false
}

@MainActor
final class RecordingBar {
    private var panel: NSPanel?
    private var timer: Timer?
    private let model = RecordingBarModel()

    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?
    var onToggleMic: (() -> Void)?

    var isOpen: Bool { panel != nil }

    /// Show the bar. `elapsed` is polled for the timer (the recorder's own
    /// `recordedDuration`). The mic button only appears when `micAvailable`.
    func show(micAvailable: Bool, elapsed: @escaping () -> TimeInterval) {
        close()
        let root = RecordingBarView(
            model: model,
            micAvailable: micAvailable,
            onToggleMic: { [weak self] in self?.onToggleMic?() },
            onStop: { [weak self] in self?.onStop?() },
            onCancel: { [weak self] in self?.onCancel?() }
        )
        let hosting = NSHostingController(rootView: root)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        WindowChrome.own(panel)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.animationBehavior = .none
        // Never let the bar leak into the recording.
        panel.sharingType = .none
        panel.contentView = hosting.view
        hosting.view.layoutSubtreeIfNeeded()
        panel.setContentSize(hosting.view.fittingSize)
        position(panel)
        panel.orderFrontRegardless()
        self.panel = panel

        model.elapsed = elapsed()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            // The timer runs on the main run loop, so this is the main actor.
            MainActor.assumeIsolated {
                self?.model.elapsed = elapsed()
            }
        }
    }

    func close() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil
    }

    /// Reflect the microphone's mute state on the button.
    func setMicMuted(_ muted: Bool) {
        model.micMuted = muted
    }

    /// Top-centre of the display under the cursor, just below the menu bar.
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
            CGPoint(x: frame.midX - size.width / 2, y: frame.maxY - size.height - 16)
        )
    }
}
