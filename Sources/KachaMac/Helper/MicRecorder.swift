// Microphone capture, separate from the ScreenCaptureKit stream.
//
// SCRecordingOutput stops the recording when the stream configuration changes,
// so the microphone cannot be toggled through `SCStream`. Instead the mic is
// captured here with AVFoundation and muxed into the movie when recording ends.
// The live mute is a flag that simply skips appending samples.

import AVFoundation
import CoreMedia

// SAFETY: all mutable state is confined to `queue`; the class is only a
// coordinator around that serial queue.
final class MicRecorder: NSObject, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.kacha.mic")
    private let session = AVCaptureSession()
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var url: URL?
    private var muted = false
    private var sessionStarted = false
    private var firstSampleTime: CMTime = .invalid

    /// Microphone capture needs an `NSMicrophoneUsageDescription` in the app
    /// bundle; without it (e.g. the bare binary) requesting access crashes, so
    /// the feature is disabled.
    static var isSupported: Bool {
        MicrophonePermission.status != .unavailable
    }

    /// Start capturing the microphone into `url`. Returns false when the mic is
    /// unavailable or access was denied.
    func start(to url: URL) async -> Bool {
        guard Self.isSupported else { return false }
        guard await MicrophonePermission.request() else { return false }
        return await withCheckedContinuation { continuation in
            queue.async {
                do {
                    try self.configure(url: url)
                    self.session.startRunning()
                    continuation.resume(returning: true)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }

    /// Mute / unmute without interrupting the capture session.
    func setMuted(_ value: Bool) {
        queue.async { self.muted = value }
    }

    /// Stop and finalize. Calls back with the written file (or nil when no audio
    /// was captured) and the host-clock time of the first sample, so the caller
    /// can align it with the video.
    func stop(completion: @escaping (URL?, CMTime) -> Void) {
        queue.async {
            self.session.stopRunning()
            guard let writer = self.writer else {
                completion(nil, .invalid)
                return
            }
            self.input?.markAsFinished()
            let hadAudio = self.sessionStarted
            let url = self.url
            let first = self.firstSampleTime
            writer.finishWriting {
                completion(hadAudio ? url : nil, first)
            }
        }
    }

    // MARK: - Setup

    private func configure(url: URL) throws {
        guard let device = AVCaptureDevice.default(for: .audio) else {
            throw RecordingError.startFailed("找不到麦克风。")
        }
        let deviceInput = try AVCaptureDeviceInput(device: device)

        session.beginConfiguration()
        if session.canAddInput(deviceInput) {
            session.addInput(deviceInput)
        }
        let dataOutput = AVCaptureAudioDataOutput()
        dataOutput.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(dataOutput) {
            session.addOutput(dataOutput)
        }
        session.commitConfiguration()

        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128_000,
        ]
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        writerInput.expectsMediaDataInRealTime = true
        if writer.canAdd(writerInput) {
            writer.add(writerInput)
        }
        writer.startWriting()

        self.writer = writer
        self.input = writerInput
        self.url = url
        self.sessionStarted = false
        self.firstSampleTime = .invalid
        self.muted = false
    }
}

extension MicRecorder: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard !muted, let writer, let input, writer.status == .writing,
            input.isReadyForMoreMediaData
        else {
            return
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if !sessionStarted {
            firstSampleTime = pts
            writer.startSession(atSourceTime: .zero)
            sessionStarted = true
        }
        // Rebase the sample to start at zero (the writer session), keeping the
        // original host-clock time in `firstSampleTime` for alignment.
        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sampleBuffer),
            presentationTimeStamp: CMTimeSubtract(pts, firstSampleTime),
            decodeTimeStamp: .invalid
        )
        var retimed: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &retimed
        )
        if status == noErr, let retimed {
            input.append(retimed)
        }
    }
}
