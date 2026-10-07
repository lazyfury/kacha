// Mix the system audio recorded with the video and the separately captured
// microphone into one audio track.
//
// `SCRecordingOutput` writes the system audio inside the movie; the microphone
// lives in its own file. `AVAssetReaderAudioMixOutput` mixes two audio tracks
// into a single PCM stream, which is then encoded to AAC and muxed back with the
// video.

import AVFoundation
import CoreMedia

enum AudioMixer {
    /// Mix the system audio inside `video` with `microphone` (delayed by
    /// `offset`) into one AAC file at `output`. Returns `output`, or nil on
    /// failure.
    static func mix(
        systemAudio video: URL,
        microphone: URL,
        offset: CMTime,
        output: URL
    ) async -> URL? {
        let videoAsset = AVURLAsset(url: video)
        let micAsset = AVURLAsset(url: microphone)
        guard
            let systemTrack = try? await videoAsset.loadTracks(withMediaType: .audio).first,
            let micTrack = try? await micAsset.loadTracks(withMediaType: .audio).first,
            let systemDuration = try? await videoAsset.load(.duration),
            let micDuration = try? await micAsset.load(.duration)
        else {
            return nil
        }

        let composition = AVMutableComposition()
        guard
            let compositionSystem = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ),
            let compositionMic = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
        else {
            return nil
        }
        try? compositionSystem.insertTimeRange(
            CMTimeRange(start: .zero, duration: systemDuration),
            of: systemTrack,
            at: .zero
        )
        // Trim the microphone to the system-audio length so a longer mic file
        // cannot extend the mixed track past the video.
        let start = CMTimeMaximum(offset, .zero)
        let available = CMTimeSubtract(systemDuration, start)
        let micRange = CMTimeMinimum(micDuration, CMTimeMaximum(available, .zero))
        try? compositionMic.insertTimeRange(
            CMTimeRange(start: .zero, duration: micRange),
            of: micTrack,
            at: start
        )

        guard let reader = try? AVAssetReader(asset: composition) else { return nil }
        let pcmSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let mixOutput = AVAssetReaderAudioMixOutput(
            audioTracks: [compositionSystem, compositionMic],
            audioSettings: pcmSettings
        )
        guard reader.canAdd(mixOutput) else { return nil }
        reader.add(mixOutput)
        guard reader.startReading() else { return nil }

        guard let writer = try? AVAssetWriter(outputURL: output, fileType: .m4a) else {
            return nil
        }
        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 160_000,
            ]
        )
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { return nil }
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let context = MixContext(input: input, output: mixOutput, writer: writer)
        await withCheckedContinuation { continuation in
            context.continuation = continuation
            input.requestMediaDataWhenReady(on: DispatchQueue(label: "com.kacha.mix")) {
                while context.input.isReadyForMoreMediaData {
                    if let buffer = context.output.copyNextSampleBuffer() {
                        context.input.append(buffer)
                    } else {
                        context.input.markAsFinished()
                        context.writer.finishWriting {
                            context.continuation?.resume()
                            context.continuation = nil
                        }
                        return
                    }
                }
            }
        }
        return writer.status == .completed ? output : nil
    }
}

/// Carries the reader / writer across the `requestMediaDataWhenReady` block.
/// SAFETY: the block runs on one serial queue, so the access is serialized.
private final class MixContext: @unchecked Sendable {
    let input: AVAssetWriterInput
    let output: AVAssetReaderAudioMixOutput
    let writer: AVAssetWriter
    var continuation: CheckedContinuation<Void, Never>?

    init(
        input: AVAssetWriterInput,
        output: AVAssetReaderAudioMixOutput,
        writer: AVAssetWriter
    ) {
        self.input = input
        self.output = output
        self.writer = writer
    }
}
