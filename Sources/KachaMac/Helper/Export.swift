// Clipboard and save-panel helpers shared by the editor, the pinned windows and
// the overlay. One save path means every export reports failures the same way.

import AppKit
import UniformTypeIdentifiers

enum Export {
    /// Copy PNG data to the general pasteboard.
    static func copyPNG(_ data: Data) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: .png)
    }

    /// Copy a plain string (e.g. the colour picker's hex).
    static func copyString(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    /// A timestamped capture name (`kacha-20240102-030405.png`), shared by the
    /// editor, the overlay's quick save and the pinned windows.
    static func timestampedName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "kacha-" + formatter.string(from: Date()) + ".png"
    }

    /// `name` made unique against `existing` by appending a numeric suffix
    /// (`kacha.png` → `kacha 2.png`). Pure, so it is covered by `--selfcheck`.
    static func deduplicatedName(_ name: String, existing: Set<String>) -> String {
        guard existing.contains(name) else { return name }
        let url = URL(fileURLWithPath: name)
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var index = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            if !existing.contains(candidate) { return candidate }
            index += 1
        }
    }

    /// Save `data` as a PNG. With `directory` set the file is written straight
    /// into it (no panel), picking a unique name; otherwise a save panel is
    /// shown. Returns the written URL, or nil when the user cancels / the write
    /// fails (the failure is shown).
    @discardableResult
    static func savePNG(_ data: Data, suggestedName: String, directory: URL? = nil) -> URL? {
        if let directory {
            return write(data, into: directory, suggestedName: suggestedName)
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            try data.write(to: url)
            return url
        } catch {
            present("保存失败", error.localizedDescription)
            return nil
        }
    }

    /// Write `data` into `directory` under a non-colliding `suggestedName`.
    private static func write(_ data: Data, into directory: URL, suggestedName: String) -> URL? {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            let existing = Set(
                (try? manager.contentsOfDirectory(atPath: directory.path)) ?? []
            )
            let url = directory.appendingPathComponent(
                deduplicatedName(suggestedName, existing: existing)
            )
            try data.write(to: url)
            return url
        } catch {
            present("保存失败", error.localizedDescription)
            return nil
        }
    }

    private static func present(_ message: String, _ informative: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = informative
        alert.runModal()
    }
}
