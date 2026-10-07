// The settings window's SwiftUI content.
//
// Mirrors the macOS 26 System Settings look: a sidebar of grouped navigation
// items on the left and one pane on the right, whose options are grouped cards
// with segmented button groups. The window is a full-size content view, so the
// sidebar/header clear the traffic lights themselves.

import AppKit
import SwiftUI

/// The settings panes shown in the sidebar.
private enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case shortcuts
    case recording
    case saving

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "通用"
        case .shortcuts: return "快捷键"
        case .recording: return "录制"
        case .saving: return "保存"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .shortcuts: return "keyboard"
        case .recording: return "record.circle"
        case .saving: return "folder"
        }
    }
}

struct SettingsRootView: View {
    let onHotkeyChange: () -> Void

    @State private var section: SettingsSection? = .general
    @State private var captureHotkey = Preferences.captureHotkey
    @State private var pickerHotkey = Preferences.pickerHotkey
    @State private var fullScreenHotkey = Preferences.fullScreenHotkey
    @State private var recordHotkey = Preferences.recordHotkey
    @State private var recording = Preferences.recordingConfig
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var playSound = Preferences.playSound
    @State private var delaySeconds = Preferences.delaySeconds
    @State private var saveDirectory = Preferences.saveDirectory

    private var loginAvailable: Bool { LaunchAtLogin.isAvailable }

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                Section("应用") {
                    ForEach([SettingsSection.general, .shortcuts]) { item in
                        Label(item.title, systemImage: item.symbol)
                            .tag(item)
                    }
                }
                Section("录制与保存") {
                    ForEach([SettingsSection.recording, .saving]) { item in
                        Label(item.title, systemImage: item.symbol)
                            .tag(item)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            Form {
                switch section ?? .general {
                case .general: generalPane
                case .shortcuts: shortcutsPane
                case .recording: recordingPane
                case .saving: savingPane
                }
            }
            .formStyle(.grouped)
            .toolbar {
                ToolbarItem {
                    Button {
                        showHelp()
                    } label: {
                        Image(systemName: "questionmark")
                    }
                    .help("帮助")
                }
            }
        }
        .frame(minWidth: 680, minHeight: 480)
        .onChange(of: recording) { _, value in
            Preferences.recordingConfig = value
        }
    }

    // MARK: - Panes

    private var generalPane: some View {
        Group {
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

            Section {
                sectionHeader("截图", "延时截图会在抓屏前倒计时；截图完成后播放系统提示音。")
                Picker("延时", selection: delayBinding) {
                    ForEach(Preferences.delayChoices, id: \.self) { seconds in
                        Text(seconds == 0 ? "不延时" : "\(seconds) 秒").tag(seconds)
                    }
                }
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
        }
    }

    private var shortcutsPane: some View {
        Section {
            sectionHeader("快捷键", "点右侧的按钮，然后按下新的组合键；按 Esc 取消。")
            hotkeyRow("截图", hotkey: $captureHotkey) {
                Preferences.captureHotkey = $0
            }
            hotkeyRow("全屏截图", hotkey: $fullScreenHotkey) {
                Preferences.fullScreenHotkey = $0
            }
            hotkeyRow("录制屏幕", hotkey: $recordHotkey) {
                Preferences.recordHotkey = $0
            }
            hotkeyRow("取色器", hotkey: $pickerHotkey) {
                Preferences.pickerHotkey = $0
            }
            HStack {
                Spacer(minLength: 0)
                Button("恢复默认", action: resetHotkeys)
            }
        }
    }

    private var recordingPane: some View {
        Section {
            sectionHeader("录制", "录制屏幕时的编码与音频选项；麦克风需要 macOS 15 与麦克风权限。")
            recordingPicker("帧率", selection: $recording.frameRate) {
                ForEach(RecordingFrameRate.allCases, id: \.self) {
                    Text($0.label).tag($0)
                }
            }
            recordingPicker("编码", selection: $recording.codec) {
                ForEach(RecordingCodec.allCases, id: \.self) {
                    Text($0.label).tag($0)
                }
            }
            recordingPicker("容器", selection: $recording.container) {
                ForEach(RecordingContainer.allCases, id: \.self) {
                    Text($0.label).tag($0)
                }
            }
            recordingPicker("音频", selection: $recording.audio) {
                ForEach(RecordingAudio.allCases, id: \.self) {
                    Text($0.label).tag($0)
                }
            }
            recordingPicker("开始前倒数", selection: $recording.countdown) {
                ForEach(Preferences.countdownChoices, id: \.self) {
                    Text($0 == 0 ? "关闭" : "\($0) 秒").tag($0)
                }
            }
            Toggle("显示光标", isOn: $recording.showCursor)
                .toggleStyle(.switch)
            Toggle("点击高亮", isOn: $recording.showClicks)
                .toggleStyle(.switch)
        }
    }

    private var savingPane: some View {
        Section {
            sectionHeader(
                "保存",
                "设好目录后，截图与录屏会直接存到这里；未设置时每次弹出保存面板。"
            )
            LabeledContent {
                HStack(spacing: 8) {
                    Button("选择…", action: chooseSaveDirectory)
                    if saveDirectory != nil {
                        Button("清除", action: clearSaveDirectory)
                    }
                }
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text("保存目录")
                    Text(saveDirectory?.path ?? "每次询问")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
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

    /// A labelled segmented control (renders as a group of buttons on macOS).
    private func recordingPicker<Value: Hashable>(
        _ title: String,
        selection: Binding<Value>,
        @ViewBuilder content: () -> some View
    ) -> some View {
        Picker(title, selection: selection) {
            content()
        }
        .pickerStyle(.segmented)
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

    /// Persist the delayed-capture preset on change.
    private var delayBinding: Binding<Int> {
        Binding(
            get: { delaySeconds },
            set: { newValue in
                delaySeconds = newValue
                Preferences.delaySeconds = newValue
            }
        )
    }

    private func resetHotkeys() {
        captureHotkey = .default
        pickerHotkey = .pickerDefault
        fullScreenHotkey = .fullScreenDefault
        recordHotkey = .recordDefault
        Preferences.captureHotkey = .default
        Preferences.pickerHotkey = .pickerDefault
        Preferences.fullScreenHotkey = .fullScreenDefault
        Preferences.recordHotkey = .recordDefault
        onHotkeyChange()
    }

    /// Pick the folder captures save into directly.
    private func chooseSaveDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Preferences.saveDirectory = url
        saveDirectory = url
    }

    /// Go back to asking for a location on every save.
    private func clearSaveDirectory() {
        Preferences.saveDirectory = nil
        saveDirectory = nil
    }

    private func showHelp() {
        let alert = NSAlert()
        alert.messageText = "快捷键"
        alert.informativeText = """
        截图：框选区域、点击窗口或点击桌面。
        全屏截图：抓取鼠标所在的整块屏幕。
        录制屏幕：框选区域、点窗口或整屏录成视频。
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
