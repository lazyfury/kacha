// The menu-bar item: kacha's entry point when it is not driven from the menu.

import AppKit

@MainActor
final class MenuBar: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let onCapture: () -> Void
    private let onDelayedCapture: (Int) -> Void
    private let onFullScreen: () -> Void
    private let onRecord: () -> Void
    private let onPicker: () -> Void
    private let onViewer: () -> Void
    private let onSettings: () -> Void
    private let onClosePins: () -> Void
    private let onQuit: () -> Void
    private var captureItem: NSMenuItem?
    private var fullScreenItem: NSMenuItem?
    private var recordItem: NSMenuItem?
    private var pickerItem: NSMenuItem?
    private var delayItems: [NSMenuItem] = []

    init(
        onCapture: @escaping () -> Void,
        onDelayedCapture: @escaping (Int) -> Void,
        onFullScreen: @escaping () -> Void,
        onRecord: @escaping () -> Void,
        onPicker: @escaping () -> Void,
        onViewer: @escaping () -> Void,
        onSettings: @escaping () -> Void,
        onClosePins: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.onCapture = onCapture
        self.onDelayedCapture = onDelayedCapture
        self.onFullScreen = onFullScreen
        self.onRecord = onRecord
        self.onPicker = onPicker
        self.onViewer = onViewer
        self.onSettings = onSettings
        self.onClosePins = onClosePins
        self.onQuit = onQuit
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
    }

    func install() {
        // A slightly larger menu-bar glyph: configure the symbol and let the
        // button scale it up as well as down. The icon stays the same while
        // recording — macOS already shows its own recording indicator, so
        // swapping this one only adds a second, confusing badge.
        let configuration = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        if let image = NSImage(
            systemSymbolName: "camera.viewfinder",
            accessibilityDescription: "kacha"
        )?.withSymbolConfiguration(configuration) {
            statusItem.button?.image = image
            statusItem.button?.imageScaling = .scaleProportionallyDown
        } else {
            statusItem.button?.title = "◲"
        }

        let menu = NSMenu()
        let capture = NSMenuItem(title: "截图", action: #selector(captureClicked), keyEquivalent: "")
        capture.target = self
        menu.addItem(capture)
        self.captureItem = capture

        // The delayed-capture presets: choosing one sets the default and starts
        // the countdown. The current default carries a checkmark.
        let delay = NSMenuItem(title: "延时截图", action: nil, keyEquivalent: "")
        let delayMenu = NSMenu()
        for seconds in Preferences.delayChoices {
            let item = NSMenuItem(
                title: seconds == 0 ? "不延时" : "\(seconds) 秒",
                action: #selector(delayClicked(_:)),
                keyEquivalent: ""
            )
            item.tag = seconds
            item.target = self
            delayMenu.addItem(item)
            delayItems.append(item)
        }
        delay.submenu = delayMenu
        menu.addItem(delay)

        let fullScreen = NSMenuItem(
            title: "全屏截图",
            action: #selector(fullScreenClicked),
            keyEquivalent: ""
        )
        fullScreen.target = self
        menu.addItem(fullScreen)
        self.fullScreenItem = fullScreen

        let record = NSMenuItem(
            title: "录制屏幕",
            action: #selector(recordClicked),
            keyEquivalent: ""
        )
        record.target = self
        menu.addItem(record)
        self.recordItem = record

        let picker = NSMenuItem(title: "取色器", action: #selector(pickerClicked), keyEquivalent: "")
        picker.target = self
        menu.addItem(picker)
        self.pickerItem = picker

        let viewer = NSMenuItem(title: "看图", action: #selector(viewerClicked), keyEquivalent: "")
        viewer.target = self
        menu.addItem(viewer)

        menu.addItem(.separator())
        let closePins = NSMenuItem(
            title: "关闭所有钉图",
            action: #selector(closePinsClicked),
            keyEquivalent: ""
        )
        closePins.target = self
        menu.addItem(closePins)

        let settings = NSMenuItem(title: "设置…", action: #selector(settingsClicked), keyEquivalent: ",")
        settings.keyEquivalentModifierMask = [.command]
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 kacha", action: #selector(quitClicked), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        menu.delegate = self
        updateShortcuts()
    }

    /// Refresh the menu state (shortcuts, delay checkmark) just before it opens.
    func menuWillOpen(_ menu: NSMenu) {
        updateShortcuts()
    }

    /// Reflect the recording state on the record menu item: while recording the
    /// item is disabled (no second session) and reads "正在录制…".
    func setRecording(_ recording: Bool) {
        recordItem?.title = recording ? "正在录制…" : "录制屏幕"
        recordItem?.isEnabled = !recording
    }

    /// Show the current shortcuts next to the menu items.
    func updateShortcuts() {
        Preferences.captureHotkey.apply(to: captureItem)
        Preferences.fullScreenHotkey.apply(to: fullScreenItem)
        Preferences.recordHotkey.apply(to: recordItem)
        Preferences.pickerHotkey.apply(to: pickerItem)
        for item in delayItems {
            item.state = item.tag == Preferences.delaySeconds ? .on : .off
        }
    }

    @objc private func captureClicked() { onCapture() }
    @objc private func delayClicked(_ sender: NSMenuItem) { onDelayedCapture(sender.tag) }
    @objc private func recordClicked() { onRecord() }
    @objc private func fullScreenClicked() { onFullScreen() }
    @objc private func pickerClicked() { onPicker() }
    @objc private func viewerClicked() { onViewer() }
    @objc private func settingsClicked() { onSettings() }
    @objc private func closePinsClicked() { onClosePins() }
    @objc private func quitClicked() { onQuit() }
}
