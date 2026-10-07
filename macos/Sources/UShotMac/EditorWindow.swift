// The editor window: a normal titled window with a toolbar and a Core Graphics
// canvas. Closing it (red button or ⌘W) tears everything down.

import AppKit

final class EditorWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var canvas: EditorCanvasView?
    private var state: EditorState?
    private var session: CaptureSession?
    private var toolButtons: [NSButton] = []
    private let pins: PinWindows

    init(pins: PinWindows) {
        self.pins = pins
    }

    var isOpen: Bool { window != nil }

    /// Open an editor for `session` (the composed image lives in it).
    func show(session: CaptureSession) {
        close()

        let composed = session.composed
        let imageSize = composed.map { CGSize(width: $0.width, height: $0.height) }
            ?? CGSize(width: 900, height: 600)
        let visible = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let contentSize = CGSize(
            width: min(max(imageSize.width + 32, 640), visible.width - 40),
            height: min(max(imageSize.height + 96, 460), visible.height - 40)
        )

        let state = EditorState()
        if let composed {
            let size = (composed.width, composed.height)
            state.stroke = defaultStroke(size)
            state.textSize = defaultTextSize(size)
        }
        self.state = state
        self.session = session

        let canvas = EditorCanvasView(session: session, state: state)
        self.canvas = canvas

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ushot — 编辑"
        // ARC owns this window; AppKit must not also release it on close.
        window.isReleasedWhenClosed = false
        window.delegate = self

        let container = NSView(frame: NSRect(origin: .zero, size: contentSize))
        let toolbar = buildToolbar()
        container.addSubview(toolbar)
        container.addSubview(canvas)
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        canvas.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            toolbar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            toolbar.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -8),
            canvas.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 8),
            canvas.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        window.contentView = container
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
        self.window = window
        updateToolButtons()
    }

    // MARK: - Toolbar

    private func buildToolbar() -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 6
        row.alignment = .centerY

        toolButtons = Tool.allCases.enumerated().map { index, tool in
            let button = NSButton(title: tool.label, target: self, action: #selector(selectTool(_:)))
            button.bezelStyle = .rounded
            button.tag = index
            row.addArrangedSubview(button)
            return button
        }
        row.addArrangedSubview(spacer(width: 12))
        row.addArrangedSubview(actionButton("撤销", #selector(undo)))
        row.addArrangedSubview(actionButton("重做", #selector(redo)))
        row.addArrangedSubview(actionButton("复制", #selector(copyImage)))
        row.addArrangedSubview(actionButton("保存", #selector(saveImage)))
        row.addArrangedSubview(actionButton("钉图", #selector(pinImage)))
        row.addArrangedSubview(actionButton("关闭", #selector(closeEditor)))
        return row
    }

    private func actionButton(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private func spacer(width: CGFloat) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: width).isActive = true
        return view
    }

    @objc private func selectTool(_ sender: NSButton) {
        guard Tool.allCases.indices.contains(sender.tag) else { return }
        state?.tool = Tool.allCases[sender.tag]
        updateToolButtons()
    }

    private func updateToolButtons() {
        let current = state?.tool
        for (index, button) in toolButtons.enumerated() {
            let active = Tool.allCases[index] == current
            button.bezelColor = active ? .controlAccentColor : nil
        }
    }

    @objc private func undo() {
        state?.undo()
        canvas?.needsDisplay = true
    }

    @objc private func redo() {
        state?.redoLast()
        canvas?.needsDisplay = true
    }

    @objc private func copyImage() {
        guard let data = canvas?.renderExport() else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: .png)
    }

    @objc private func saveImage() {
        guard let data = canvas?.renderExport() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = Self.timestamp() + ".png"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try data.write(to: url)
            } catch {
                let alert = NSAlert()
                alert.messageText = "保存失败"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    @objc private func pinImage() {
        guard let data = canvas?.renderExport() else { return }
        pins.pin(data)
    }

    @objc private func closeEditor() {
        close()
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "ushot-" + formatter.string(from: Date())
    }

    // MARK: - Teardown

    /// Debug: render the editor's current image (the `--smoke-export` path).
    func exportForSmoke() -> Data? {
        canvas?.renderExport()
    }

    func windowWillClose(_ notification: Notification) {
        close()
    }

    func close() {
        window?.orderOut(nil)
        window = nil
        canvas = nil
        state = nil
        session = nil
        toolButtons = []
    }
}
