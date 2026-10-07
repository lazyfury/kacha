// The settings window's SwiftUI content.
//
// A native grouped Form (the modern macOS Settings look, and it inherits the
// macOS 26 chrome automatically). The hotkey recorder stays AppKit and is
// embedded with NSViewRepresentable.

import AppKit
import SwiftUI

struct SettingsRootView: View {
    let onHotkeyChange: () -> Void

    @State private var captureHotkey = Preferences.captureHotkey
    @State private var pickerHotkey = Preferences.pickerHotkey
    @State private var fullScreenHotkey = Preferences.fullScreenHotkey
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    private var loginAvailable: Bool { LaunchAtLogin.isAvailable }

    var body: some View {
        Form {
            Section {
                hotkeyRow("截图", symbol: "camera.viewfinder", hotkey: $captureHotkey) {
                    Preferences.captureHotkey = $0
                }
                hotkeyRow(
                    "全屏截图",
                    symbol: "arrow.up.left.and.arrow.down.right",
                    hotkey: $fullScreenHotkey
                ) {
                    Preferences.fullScreenHotkey = $0
                }
                hotkeyRow("取色器", symbol: "eyedropper", hotkey: $pickerHotkey) {
                    Preferences.pickerHotkey = $0
                }
            } header: {
                Label("快捷键", systemImage: "keyboard")
            } footer: {
                Text("点右边的按钮，然后按下新的组合键；按 Esc 取消。")
            }

            Section {
                Toggle("开机时启动", isOn: loginBinding)
                    .toggleStyle(.switch)
                    .disabled(!loginAvailable)
                if !loginAvailable {
                    Text("从 .app 运行时可设置开机启动。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Label("通用", systemImage: "gearshape")
            }

            Section {
                Button("恢复默认快捷键", action: resetHotkeys)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .frame(minHeight: 360)
    }

    private func hotkeyRow(
        _ title: String,
        symbol: String,
        hotkey: Binding<Hotkey>,
        apply: @escaping (Hotkey) -> Void
    ) -> some View {
        LabeledContent {
            HotkeyRecorder(hotkey: hotkey) { value in
                apply(value)
                onHotkeyChange()
            }
        } label: {
            Label(title, systemImage: symbol)
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
        fullScreenHotkey = .fullScreenDefault
        Preferences.captureHotkey = .default
        Preferences.pickerHotkey = .pickerDefault
        Preferences.fullScreenHotkey = .fullScreenDefault
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
