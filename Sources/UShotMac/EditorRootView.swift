// The editor window's SwiftUI content.
//
// SwiftUI draws a floating "Liquid Glass" (macOS 26) toolbar over the existing
// AppKit canvas, which is embedded unchanged through `NSViewRepresentable`. On
// macOS 14–15 the toolbar falls back to a material bar with plain buttons.

import AppKit
import SwiftUI

/// Root view: the canvas fills the window, the toolbar floats on top.
struct EditorRootView: View {
    @ObservedObject var state: EditorState
    let canvas: EditorCanvasView
    let onCopy: () -> Void
    let onSave: () -> Void
    let onPin: () -> Void
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            CanvasRepresentable(canvas: canvas)
            EditorToolbar(
                state: state,
                canvas: canvas,
                onCopy: onCopy,
                onSave: onSave,
                onPin: onPin,
                onClose: onClose
            )
            .padding(.top, 12)
        }
        .frame(minWidth: 320, minHeight: 240)
    }
}

/// Embeds the AppKit canvas; it owns its own drawing and mouse handling.
private struct CanvasRepresentable: NSViewRepresentable {
    let canvas: EditorCanvasView

    func makeNSView(context: Context) -> EditorCanvasView { canvas }

    func updateNSView(_ nsView: EditorCanvasView, context: Context) {
        nsView.needsDisplay = true
    }
}

/// The floating toolbar: tools, undo / redo and the output actions.
private struct EditorToolbar: View {
    @ObservedObject var state: EditorState
    let canvas: EditorCanvasView
    let onCopy: () -> Void
    let onSave: () -> Void
    let onPin: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Tool.allCases, id: \.self) { tool in
                ToolbarButton(
                    symbol: tool.showsTextOnly ? nil : tool.symbol,
                    title: tool.label,
                    active: state.tool == tool,
                    disabled: false,
                    showsLabel: tool.showsLabel
                ) {
                    state.tool = tool
                }
            }

            separator

            ToolbarButton(
                symbol: ToolbarSymbol.undo,
                title: "撤销",
                active: false,
                disabled: state.annotations.isEmpty
            ) {
                state.undo()
                canvas.needsDisplay = true
            }
            ToolbarButton(
                symbol: ToolbarSymbol.redo,
                title: "重做",
                active: false,
                disabled: state.redo.isEmpty
            ) {
                state.redoLast()
                canvas.needsDisplay = true
            }

            separator

            ToolbarButton(
                symbol: ToolbarSymbol.copy,
                title: "复制",
                active: false,
                disabled: false,
                showsLabel: true,
                action: onCopy
            )
            ToolbarButton(
                symbol: ToolbarSymbol.save,
                title: "保存",
                active: false,
                disabled: false,
                showsLabel: true,
                action: onSave
            )
            ToolbarButton(
                symbol: ToolbarSymbol.pin,
                title: "钉图",
                active: false,
                disabled: false,
                action: onPin
            )
            ToolbarButton(
                symbol: ToolbarSymbol.close,
                title: "关闭",
                active: false,
                disabled: false,
                action: onClose
            )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .modifier(GlassBarBackground())
    }

    private var separator: some View {
        Divider()
            .frame(height: 20)
            .padding(.horizontal, 4)
    }
}

/// One toolbar button: an optional SF Symbol, an optional Chinese label, and a
/// filled accent capsule when it is the active tool.
private struct ToolbarButton: View {
    let symbol: String?
    let title: String
    let active: Bool
    let disabled: Bool
    var showsLabel = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 14, weight: .medium))
                }
                if showsLabel {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .frame(minWidth: showsLabel ? nil : 28, minHeight: 26)
            .padding(.horizontal, showsLabel ? 8 : 0)
            .foregroundStyle(active ? Color.white : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(active ? Color.accentColor : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .help(title)
        .accessibilityLabel(title)
    }
}

/// Liquid Glass on macOS 26, a material bar on macOS 14–15.
private struct GlassBarBackground: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(
                .regular,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
        } else {
            content.background(
                .bar,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
        }
    }
}
