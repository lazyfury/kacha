// The settings window's SwiftUI content: the capture / picker hotkeys and
// launch-at-login. The AppKit hotkey recorder is embedded via
// `NSViewRepresentable`; the card is Liquid Glass on macOS 26.

import AppKit
import SwiftUI

struct SettingsRootView: View {
    let onHotkeyChange: () -> Void

    @State private var captureHotkey = Preferences.captureHotkey
    @State private var pickerHotkey = Preferences.pickerHotkey
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    private let loginAvailable = LaunchAtLogin.isAvailable

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            row("截图快捷键") {
                HotkeyRecorder(hotkey: $captureHotkey) { hotkey in
                    Preferences.captureHotkey = hotkey
                    onHotkeyChange()
                }
            }
            row("取色器快捷键") {
                HotkeyRecorder(hotkey: $pickerHotkey) { hotkey in
                    Preferences.pickerHotkey = hotkey
                    onHotkeyChange()
                }
            }

            Toggle("开机时启动", isOn: loginBinding)
                .toggleStyle(.checkbox)
                .disabled(!loginAvailable)

            if !loginAvailable {
                Text("从 .app 运行时可设置开机启动。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                Spacer()
                Button("恢复默认快捷键", action: resetHotkeys)
            }
        }
        .padding(24)
        .frame(width: 440)
        .modifier(SettingsGlassBackground())
    }

    private func row<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .frame(width: 110, alignment: .trailing)
            content()
            Spacer()
        }
    }

    /// Only commit the change (and update the UI) when the system call succeeds.
    private var loginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { newValue in
                if let error = LaunchAtLogin.set(newValue) {
                    present(error)
                } else {
                    launchAtLogin = newValue
                }
            }
        )
    }

    private func resetHotkeys() {
        captureHotkey = .default
        pickerHotkey = .pickerDefault
        Preferences.captureHotkey = .default
        Preferences.pickerHotkey = .pickerDefault
        onHotkeyChange()
    }

    private func present(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "无法修改开机启动"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}

/// Embeds the AppKit recorder; the binding keeps its title in sync.
private struct HotkeyRecorder: NSViewRepresentable {
    @Binding var hotkey: Hotkey
    let onChange: (Hotkey) -> Void

    func makeNSView(context: Context) -> HotkeyRecorderView {
        let view = HotkeyRecorderView(hotkey: hotkey)
        view.onChange = { newValue in
            hotkey = newValue
            onChange(newValue)
        }
        return view
    }

    func updateNSView(_ nsView: HotkeyRecorderView, context: Context) {
        if nsView.hotkey != hotkey {
            nsView.hotkey = hotkey
        }
        nsView.onChange = { newValue in
            hotkey = newValue
            onChange(newValue)
        }
    }
}

/// Liquid Glass on macOS 26, a material card on macOS 14–15.
private struct SettingsGlassBackground: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(
                .regular,
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
        } else {
            content.background(
                .regularMaterial,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
        }
    }
}
