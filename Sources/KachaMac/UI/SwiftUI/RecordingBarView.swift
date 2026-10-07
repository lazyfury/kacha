// The recording control bar's SwiftUI content: a red dot, the timer and the
// stop / cancel buttons. Hosted in a floating, non-activating panel.

import SwiftUI

struct RecordingBarView: View {
    @ObservedObject var model: RecordingBarModel
    let onStop: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.red)
                .frame(width: 9, height: 9)
            Text(formatDuration(model.elapsed))
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
                .frame(minWidth: 52, alignment: .leading)
            Divider()
                .frame(height: 18)
            barButton("stop.fill", help: "停止并保存", action: onStop)
            barButton("xmark", help: "取消并丢弃", action: onCancel)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .modifier(RecordingBarBackground())
    }

    private func barButton(
        _ symbol: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Liquid Glass on macOS 26, a material capsule on macOS 14–15.
private struct RecordingBarBackground: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content.background(.regularMaterial, in: Capsule())
        }
    }
}
