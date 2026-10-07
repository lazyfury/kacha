// Mux a video-only movie and a separately captured microphone file into one
// movie. Needed because the microphone is captured outside the SCStream.

import AVFoundation
import CoreMedia

enum RecordingMuxer {
    /// Combine `video` and `microphone` into `output`. `offset` is how long after
    /// the video started the microphone's first sample arrived, so the audio
    /// stays in sync. Returns `output`, or nil when either input has no usable
    /// track or the export fails.
    static func mux(
        video: URL,
        microphone: URL,
        offset: CMTime,
        output: URL,
        container: RecordingContainer
    ) async -> URL? {
        let videoAsset = AVURLAsset(url: video)
        let micAsset = AVURLAsset(url: microphone)
        guard
            let videoTrack = try? await videoAsset.loadTracks(withMediaType: .video).first,
            let micTrack = try? await micAsset.loadTracks(withMediaType: .audio).first,
            let videoDuration = try? await videoAsset.load(.duration),
            let micDuration = try? await micAsset.load(.duration)
        else {
            return nil
        }

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
        try? compositionVideo.insertTimeRange(
            CMTimeRange(start: .zero, duration: videoDuration),
            of: videoTrack,
            at: .zero
        )
        // Trim the microphone to the video length so a longer mic file cannot
        // leave a frozen video gap.
        let start = CMTimeMaximum(offset, .zero)
        let available = CMTimeSubtract(videoDuration, start)
        let micRange = CMTimeMinimum(micDuration, CMTimeMaximum(available, .zero))
        try? compositionAudio.insertTimeRange(
            CMTimeRange(start: .zero, duration: micRange),
            of: micTrack,
            at: start
        )

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
