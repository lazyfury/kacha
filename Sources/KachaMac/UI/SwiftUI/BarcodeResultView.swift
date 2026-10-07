// The barcode result sheet: the decoded payloads, each copyable.

import SwiftUI

struct BarcodeResultView: View {
    let codes: [ScannedCode]
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("识别结果")
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 8)

            if codes.isEmpty {
                Text("未识别到二维码或条码")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 240, alignment: .topLeading)
                    .padding(.horizontal, 20)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(codes.indices, id: \.self) { index in
                            row(codes[index])
                        }
                    }
                    .padding(16)
                }
                .frame(minHeight: 240)
            }

            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button("复制全部") {
                    Export.copyString(codes.map(\.payload).joined(separator: "\n"))
                }
                .disabled(codes.isEmpty)
                Button("完成", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 520, height: 380)
    }

    private func row(_ code: ScannedCode) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(code.symbology)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)
            Text(code.payload)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                Export.copyString(code.payload)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .help("复制")
        }
        .padding(10)
        .background(
            Color(nsColor: .textBackgroundColor),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }
}
