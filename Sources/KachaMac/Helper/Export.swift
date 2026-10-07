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

    /// Present a save panel and write `data` as a PNG. Returns the written URL,
    /// or nil when the user cancels / the write fails (the failure is shown).
    @discardableResult
    static func savePNG(_ data: Data, suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            try data.write(to: url)
            return url
        } catch {
            let alert = NSAlert()
            alert.messageText = "保存失败"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return nil
        }
    }
}
