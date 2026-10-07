// The settings window's SwiftUI content.
//
// Mirrors the macOS 26 System Settings look: a title in the top bar, grouped
// cards whose section title/description live inside the card, and an action bar
// pinned to the bottom. The window is a full-size content view, so the header
// row clears the traffic lights itself.

import AppKit
import SwiftUI

struct SettingsRootView: View {
    let onHotkeyChange: () -> Void

    @State private var captureHotkey = Preferences.captureHotkey
    @State private var pickerHotkey = Preferences.pickerHotkey
    @State private var fullScreenHotkey = Preferences.fullScreenHotkey
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var playSound = Preferences.playSound

    private var loginAvailable: Bool { LaunchAtLogin.isAvailable }

    var body: some View {
        VStack(spacing: 0) {
            header
            Form {
                Section {
                    sectionHeader(
                        "快捷键",
                        "点右侧的按钮，然后按下新的组合键；按 Esc 取消。"
                    )
                    hotkeyRow("截图", hotkey: $captureHotkey) {
                        Preferences.captureHotkey = $0
                    }
                    hotkeyRow("全屏截图", hotkey: $fullScreenHotkey) {
                        Preferences.fullScreenHotkey = $0
                    }
                    hotkeyRow("取色器", hotkey: $pickerHotkey) {
                        Preferences.pickerHotkey = $0
                    }
                }

                Section {
                    sectionHeader("截图", "截图完成后播放系统提示音。")
                    Toggle(isOn: soundBinding) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("播放声音")
                                .font(.headline)
                            Text("使用系统截图同款提示音，不额外占用安装包体积。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                }

                Section {
                    Toggle(isOn: loginBinding) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("开机时启动")
                                .font(.headline)
                            Text("从 .app 运行时可设置开机启动。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .disabled(!loginAvailable)
                }
            }
            .formStyle(.grouped)
            footer
        }
        // The window content spans the titlebar; the header row clears the
        // traffic lights itself.
        .ignoresSafeArea(edges: .top)
        .frame(width: 460)
        .frame(minHeight: 380)
    }

    // MARK: - Chrome

    /// The window title, sitting to the right of the traffic lights.
    private var header: some View {
        HStack {
            Text("设置")
                .font(.system(size: 15, weight: .semibold))
            Spacer(minLength: 0)
        }
        .padding(.leading, 82)
        .padding(.trailing, 20)
        .padding(.top, 6)
        .padding(.bottom, 12)
    }

    /// The bottom action bar: reset the shortcuts, plus a help button.
    private var footer: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            Button("恢复默认快捷键", action: resetHotkeys)
            Button {
                showHelp()
            } label: {
                Image(systemName: "questionmark")
                    .frame(width: 18, height: 18)
            }
            .buttonBorderShape(.circle)
            .help("帮助")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    // MARK: - Rows

    /// A card's title + description, rendered as the card's first row.
    private func sectionHeader(_ title: String, _ description: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.headline)
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func hotkeyRow(
        _ title: String,
        hotkey: Binding<Hotkey>,
        apply: @escaping (Hotkey) -> Void
    ) -> some View {
        LabeledContent {
            HotkeyRecorder(hotkey: hotkey) { value in
                apply(value)
                onHotkeyChange()
            }
        } label: {
            Text(title)
        }
    }

    // MARK: - Actions

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

    /// Persist on change and preview the sound when it is switched on.
    private var soundBinding: Binding<Bool> {
        Binding(
            get: { playSound },
            set: { newValue in
                playSound = newValue
                Preferences.playSound = newValue
                if newValue { ShotSound.play() }
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

    private func showHelp() {
        let alert = NSAlert()
        alert.messageText = "快捷键"
        alert.informativeText = """
        截图：框选区域、点击窗口或点击桌面。
        全屏截图：抓取鼠标所在的整块屏幕。
        取色器：在冻结的画面上取样颜色。
        """
        alert.alertStyle = .informational
        alert.runModal()
    }

    private func present(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "无法修改开机启动"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}
