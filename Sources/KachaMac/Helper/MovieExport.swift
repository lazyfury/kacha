// Shared `AVAssetExportSession` runner.
//
// `exportAsynchronously` is deprecated in macOS 15 in favour of the async
// `export(to:as:)`. Use the async API where available and fall back to the
// completion handler on macOS 14 (the deployment floor), where it is the only
// option. Keeping this in one place means `VideoConcatenator` and
// `RecordingMuxer` do not each carry the availability dance.

import AVFoundation

/// Run `export` to completion. Returns true when the export finished.
func runMovieExport(
    _ export: AVAssetExportSession,
    to output: URL,
    as fileType: AVFileType
) async -> Bool {
    if #available(macOS 15.0, *) {
        do {
            try await export.export(to: output, as: fileType)
            return true
        } catch {
            return false
        }
    }
    export.outputURL = output
    export.outputFileType = fileType
    await withCheckedContinuation { continuation in
        export.exportAsynchronously { continuation.resume() }
    }
    return export.status == .completed
}
