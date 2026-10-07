// Concatenate the recording segments produced by pause / resume into one movie.
//
// Each segment is a normalized movie (video + one audio track); joining them
// sequentially is a passthrough export of an `AVMutableComposition`.

import AVFoundation
import CoreMedia

enum VideoConcatenator {
    /// Join `urls` in order into `output`. A single input is returned as-is.
    static func concatenate(
        _ urls: [URL],
        output: URL,
        container: RecordingContainer
    ) async -> URL? {
        guard !urls.isEmpty else { return nil }
        if urls.count == 1 { return urls[0] }

        let composition = AVMutableComposition()
        guard
            let compositionVideo = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ),
            let compositionAudio = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
        else {
            return nil
        }

        // One video and one audio track, with every segment appended into them.
        // A separate track per segment would leave only the first one visible.
        var cursor = CMTime.zero
        for url in urls {
            let asset = AVURLAsset(url: url)
            guard let duration = try? await asset.load(.duration), duration > .zero else {
                continue
            }
            if let video = try? await asset.loadTracks(withMediaType: .video).first {
                try? compositionVideo.insertTimeRange(
                    CMTimeRange(start: .zero, duration: duration),
                    of: video,
                    at: cursor
                )
            }
            if let audio = try? await asset.loadTracks(withMediaType: .audio).first {
                try? compositionAudio.insertTimeRange(
                    CMTimeRange(start: .zero, duration: duration),
                    of: audio,
                    at: cursor
                )
            }
            cursor = CMTimeAdd(cursor, duration)
        }
        guard cursor > .zero else { return nil }

        guard
            let export = AVAssetExportSession(
                asset: composition,
                presetName: AVAssetExportPresetPassthrough
            )
        else {
            return nil
        }
        let fileType: AVFileType = container == .mov ? .mov : .mp4
        return await runMovieExport(export, to: output, as: fileType) ? output : nil
    }
}
