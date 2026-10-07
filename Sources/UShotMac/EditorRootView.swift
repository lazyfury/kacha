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
        ZStack(alignment: .topLeading) {
            CanvasRepresentable(canvas: canvas)
            EditorToolbar(
                state: state,
                canvas: canvas,
                onCopy: onCopy,
                onSave: onSave,
                onPin: onPin,
                onClose: onClose
            )
            .padding(.top, 10)
            .padding(.leading, 84)
        }
        .frame(minWidth: 780, minHeight: 460)
        .ignoresSafeArea()
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
                    showsLabel: tool.showsTextOnly
                ) {
                    state.tool = tool
                }
            }

            separator

            ColorControl(color: $state.color)
            StrokeControl(factor: $state.strokeFactor)
            ToolbarButton(
                symbol: state.rectangleFilled ? ToolbarSymbol.fillOn : ToolbarSymbol.fillOff,
                title: "矩形填充",
                active: state.rectangleFilled,
                disabled: false
            ) {
                state.rectangleFilled.toggle()
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
                iconOffsetY: -1,
                action: onCopy
            )
            ToolbarButton(
                symbol: ToolbarSymbol.save,
                title: "保存",
                active: false,
                disabled: false,
                showsLabel: true,
                primary: true,
                iconOffsetY: -2,
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

/// One toolbar button. Every button shares the same flat, self-drawn chrome
/// (so labels and icons stay consistent on the glass bar): an icon and/ory a
/// Chinese label, with an accent capsule when it is active or the primary
/// action.
private struct ToolbarButton: View {
    let symbol: String?
    let title: String
    let active: Bool
    let disabled: Bool
    var showsLabel = false
    var primary = false
    /// Visual nudge for the icon (points); some glyphs sit optically low.
    var iconOffsetY: CGFloat = 0
    let action: () -> Void

    private var filled: Bool { active || primary }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 14, weight: .medium))
                        .offset(y: iconOffsetY)
                }
                if showsLabel {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .frame(minWidth: showsLabel ? nil : 28, minHeight: 26)
            .padding(.horizontal, showsLabel ? 9 : 0)
            .foregroundStyle(filled ? Color.white : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(filled ? Color.accentColor : Color.clear)
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

/// The colour picker: the current colour as a swatch; the popover shows a grid
/// of colour previews.
private struct ColorControl: View {
    @Binding var color: [CGFloat]
    @State private var showing = false

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            Circle()
                .fill(Color(red: color[0], green: color[1], blue: color[2]))
                .frame(width: 15, height: 15)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 1))
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("颜色")
        .popover(isPresented: $showing) {
            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(26), spacing: 10), count: 4),
                spacing: 10
            ) {
                ForEach(AnnotationPalette.colors, id: \.self) { entry in
                    Button {
                        color = entry.rgba
                        showing = false
                    } label: {
                        Circle()
                            .fill(Color(red: entry.rgba[0], green: entry.rgba[1], blue: entry.rgba[2]))
                            .frame(width: 20, height: 20)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 1))
                            .padding(3)
                            .overlay(
                                Circle().strokeBorder(
                                    entry.rgba == color ? Color.accentColor : Color.clear,
                                    lineWidth: 2
                                )
                            )
                    }
                    .buttonStyle(.plain)
                    .help(entry.name)
                }
            }
            .padding(12)
        }
    }
}

/// The stroke-width picker: the current thickness as a line; the popover lists
/// the presets with a line preview each.
private struct StrokeControl: View {
    @Binding var factor: CGFloat
    @State private var showing = false

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            Capsule()
                .fill(Color.primary)
                .frame(width: 18, height: max(2, min(7, factor * 2.5)))
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("粗细")
        .popover(isPresented: $showing) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(AnnotationPalette.strokePresets.indices, id: \.self) { index in
                    Button {
                        factor = AnnotationPalette.strokePresets[index].factor
                        showing = false
                    } label: {
                        HStack(spacing: 10) {
                            Capsule()
                                .fill(Color.primary)
                                .frame(
                                    width: 70,
                                    height: max(
                                        2,
                                        min(10, AnnotationPalette.strokePresets[index].factor * 3)
                                    )
                                )
                            Text(AnnotationPalette.strokePresets[index].name)
                                .frame(width: 34, alignment: .leading)
                            if abs(AnnotationPalette.strokePresets[index].factor - factor) < 0.001 {
                                Image(systemName: "checkmark")
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
            .frame(width: 170)
        }
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
