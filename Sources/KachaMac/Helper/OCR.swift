// Text recognition via the system VisionKit framework.
//
// Offline, on-device and third-party-free. `analyze` wraps the same
// `ImageAnalyzer` the in-place selection overlay uses; `joinLines` post-processes
// the transcript for the "全部文字" sheet.

import CoreGraphics
import VisionKit

enum OCR {
    /// The languages to consider, best first. VisionKit tries each, so a Chinese
    /// shot and an English shot both work; a language outside the list is not
    /// recognized.
    static let languages = ["zh-Hans", "zh-Hant", "en-US"]

    /// Run the on-device text analysis, or nil when unsupported / it fails.
    static func analyze(_ image: CGImage) async -> ImageAnalysis? {
        guard ImageAnalyzer.isSupported else { return nil }
        let analyzer = ImageAnalyzer()
        var configuration = ImageAnalyzer.Configuration([.text])
        configuration.locales = languages
        return try? await analyzer.analyze(image, orientation: .up, configuration: configuration)
    }

    /// Join recognized lines for display. `merged` drops the visual line breaks
    /// (a wrapped paragraph becomes one run); a space is inserted only between
    /// two non-CJK boundaries, so Chinese text joins without stray spaces.
    static func joinLines(_ lines: [String], merged: Bool) -> String {
        guard merged else { return lines.joined(separator: "\n") }
        var result = ""
        for line in lines {
            guard !result.isEmpty else {
                result = line
                continue
            }
            if !endsWithCJK(result) && !startsWithCJK(line) {
                result += " "
            }
            result += line
        }
        return result
    }

    private static func endsWithCJK(_ text: String) -> Bool {
        text.unicodeScalars.last.map(isCJK) ?? false
    }

    private static func startsWithCJK(_ text: String) -> Bool {
        text.unicodeScalars.first.map(isCJK) ?? false
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        (0x3000...0x303F).contains(scalar.value)  // CJK punctuation
            || (0x4E00...0x9FFF).contains(scalar.value)  // CJK Unified Ideographs
            || (0xFF00...0xFFEF).contains(scalar.value)  // Fullwidth forms
    }
}
