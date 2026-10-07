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
                ToolButton(tool: tool, active: state.tool == tool) {
                    state.tool = tool
                }
            }

            separator

            ActionButton(symbol: ToolbarSymbol.undo, title: "撤销", disabled: state.annotations.isEmpty) {
                state.undo()
                canvas.needsDisplay = true
            }
            ActionButton(symbol: ToolbarSymbol.redo, title: "重做", disabled: state.redo.isEmpty) {
                state.redoLast()
                canvas.needsDisplay = true
            }

            separator

            ActionButton(symbol: ToolbarSymbol.copy, title: "复制", disabled: false, action: onCopy)
            ActionButton(symbol: ToolbarSymbol.save, title: "保存", disabled: false, action: onSave)
            ActionButton(symbol: ToolbarSymbol.pin, title: "钉图", disabled: false, action: onPin)
            ActionButton(symbol: ToolbarSymbol.close, title: "关闭", disabled: false, action: onClose)
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

/// A tool button; the active tool gets a filled accent capsule.
private struct ToolButton: View {
    let tool: Tool
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: tool.symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 30, height: 26)
                .foregroundStyle(active ? Color.white : Color.primary)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(active ? Color.accentColor : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tool.label)
        .accessibilityLabel(tool.label)
    }
}

/// An action button (undo / copy / save / …).
private struct ActionButton: View {
    let symbol: String
    let title: String
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 28, height: 26)
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
