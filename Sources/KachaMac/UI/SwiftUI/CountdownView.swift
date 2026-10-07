// The countdown HUD's SwiftUI content: the number disc and, when a recording is
// about to start with the microphone, a mute toggle.

import SwiftUI

@MainActor
final class CountdownModel: ObservableObject {
    @Published var number: Int = 0
    @Published var micMuted = false
}

struct CountdownView: View {
    @ObservedObject var model: CountdownModel
    let micAvailable: Bool
    let onToggleMic: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.72))
                Circle()
                    .strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
                Text("\(model.number)")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(.white)
                    .monospacedDigit()
            }
            .frame(width: 88, height: 88)

            if micAvailable {
                Button {
                    onToggleMic()
                } label: {
                    Image(systemName: model.micMuted ? "mic.slash.fill" : "mic.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(model.micMuted ? Color.secondary : Color.accentColor)
                        .frame(width: 40, height: 30)
                        .background(.regularMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .help(model.micMuted ? "打开麦克风" : "关闭麦克风")
            }
        }
    }
}
