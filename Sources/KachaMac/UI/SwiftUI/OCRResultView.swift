// The OCR result sheet: the recognized text, editable and copyable.

import SwiftUI

struct OCRResultView: View {
    @Binding var text: String
    /// The raw recognized lines, so the merge toggle can regenerate `text`.
    let lines: [String]
    let onClose: () -> Void

    @State private var mergeNewlines = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("识别结果")
                    .font(.headline)
                Spacer(minLength: 0)
                Toggle("合并换行", isOn: $mergeNewlines)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)

            if text.isEmpty {
                Text("未识别到文字")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 240, alignment: .topLeading)
                    .padding(.horizontal, 20)
            } else {
                TextEditor(text: $text)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(
                        Color(nsColor: .textBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .padding(.horizontal, 16)
                    .frame(minHeight: 240)
            }

            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button("复制") {
                    Export.copyString(text)
                }
                .disabled(text.isEmpty)
                Button("完成", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 520, height: 380)
        .onChange(of: mergeNewlines) { _, merged in
            text = OCR.joinLines(lines, merged: merged)
        }
    }
}
