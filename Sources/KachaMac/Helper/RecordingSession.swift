// Coordinates one recording session, including pause / resume.
//
// `SCRecordingOutput` has no pause and stops when the stream configuration
// changes, so pausing ends the current segment and resuming starts a new one.
// At stop the segments are normalized (system + mic mixed, mic muxed) and joined.

import AVFoundation
import CoreMedia

@available(macOS 15.0, *)
@MainActor
final class RecordingSession {
    private struct Segment {
        let video: URL
        let mic: URL?
        let micOffset: CMTime
    }

    private let target: RecordingTarget
    private let config: RecordingConfig
    private var userMicMuted: Bool

    private var recorder: ScreenRecorder?
    private var micRecorder: MicRecorder?
    private var currentVideo: URL?
    private var currentMic: URL?
    private var currentStartedAt: CMTime = .invalid
    private var currentMicStarted = false

    private var segments: [Segment] = []
    private var accumulated: TimeInterval = 0
    private var segmentStart: Date?
    private var finishing = false
    private var cancelled = false
    /// Whether any segment captured the microphone (for the control bar).
    private(set) var micActive = false

    /// Called once when the recording ends (or is cancelled).
    var onFinish: ((Result<URL, Error>) -> Void)?
    /// Called with a non-fatal problem (e.g. a failed audio mix) while finishing.
    var onWarning: ((String) -> Void)?

    init(target: RecordingTarget, config: RecordingConfig, micMuted: Bool) {
        self.target = target
        self.config = config
        self.userMicMuted = micMuted
    }

    /// Total recorded time, excluding pauses.
    var elapsed: TimeInterval {
        accumulated + (segmentStart.map { Date().timeIntervalSince($0) } ?? 0)
    }

    var isPaused: Bool { segmentStart == nil && !finishing }

    /// True once stop / cancel has begun and the segments are being finalized.
    var isFinishing: Bool { finishing }

    func start() async throws {
        try await beginSegment()
    }

    /// Pause (end the current segment) or resume (start a new one). Returns
    /// `false` when resuming failed, so the caller can surface it.
    @discardableResult
    func togglePause() async -> Bool {
        if segmentStart != nil {
            accumulated += Date().timeIntervalSince(segmentStart!)
            segmentStart = nil
            await endSegment()
            return true
        }
        guard !finishing else { return false }
        do {
            try await beginSegment()
            return true
        } catch {
            return false
        }
    }

    func stop() {
        guard !finishing else { return }
        finishing = true
        if let start = segmentStart {
            accumulated += Date().timeIntervalSince(start)
            segmentStart = nil
        }
        Task {
            await endSegment()
            await process()
        }
    }

    func cancel() {
        guard !finishing else { return }
        finishing = true
        cancelled = true
        segmentStart = nil
        Task {
            await endSegment()
            await process()
        }
    }

    func setMicMuted(_ muted: Bool) {
        userMicMuted = muted
        micRecorder?.setMuted(muted)
    }

    /// Best-effort synchronous cleanup for app termination: stop capturing and
    /// drop the in-flight temp files without waiting for the async pipeline.
    /// A recording cannot be finalized during quit, so this only avoids garbage.
    func abort() {
        guard !finishing else { return }
        finishing = true
        cancelled = true
        segmentStart = nil
        recorder?.cancel()
        micRecorder?.stop { _, _ in }
        for url in [currentVideo, currentMic].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: url)
        }
        currentVideo = nil
        currentMic = nil
        removeSegments()
    }

    // MARK: - Segments

    private func beginSegment() async throws {
        let videoURL = Export.recordingDestination(container: config.container)
        let recorder = ScreenRecorder()
        self.recorder = recorder
        self.currentVideo = videoURL
        try await recorder.start(target: target, options: config, to: videoURL)
        self.currentStartedAt = recorder.startedAt

        if config.audio.capturesMicrophone {
            let mic = MicRecorder()
            let micURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("kacha-mic-\(UUID().uuidString).m4a")
            self.micRecorder = mic
            self.currentMic = micURL
            self.currentMicStarted = await mic.start(to: micURL)
            mic.setMuted(userMicMuted)
            if self.currentMicStarted { micActive = true }
        } else {
            self.micRecorder = nil
            self.currentMic = nil
            self.currentMicStarted = false
        }
        segmentStart = Date()
    }

    private func endSegment() async {
        guard let recorder else { return }
        let mic = micRecorder
        let micURL = currentMic
        let micStarted = currentMicStarted
        let startedAt = currentStartedAt

        self.recorder = nil
        self.micRecorder = nil
        self.currentVideo = nil
        self.currentMic = nil
        self.currentMicStarted = false

        let micResult = await stopMic(mic, micURL: micURL, micStarted: micStarted)
        let videoURL = await stopRecorder(recorder)
        if let videoURL {
            let offset = micResult.map { CMTimeSubtract($0.first, startedAt) } ?? .invalid
            segments.append(Segment(video: videoURL, mic: micResult?.url, micOffset: offset))
        }
    }

    private func stopRecorder(_ recorder: ScreenRecorder) async -> URL? {
        await withCheckedContinuation { continuation in
            recorder.onFinish = { result in
                if case .success(let url) = result {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
            recorder.stop()
        }
    }

    private func stopMic(
        _ mic: MicRecorder?,
        micURL: URL?,
        micStarted: Bool
    ) async -> (url: URL, first: CMTime)? {
        guard let mic, micStarted, micURL != nil else {
            mic?.stop { _, _ in }
            return nil
        }
        return await withCheckedContinuation { continuation in
            mic.stop { url, first in
                if let url {
                    continuation.resume(returning: (url, first))
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - Output

    private func process() async {
        if cancelled {
            removeSegments()
            onFinish?(.failure(RecordingError.cancelled))
            return
        }

        var normalized: [URL] = []
        for segment in segments {
            if let url = await normalize(segment) {
                if url != segment.video { try? FileManager.default.removeItem(at: segment.video) }
                normalized.append(url)
            }
        }
        segments = []

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("kacha-final-\(UUID().uuidString).\(config.container.fileExtension)")
        let final = await VideoConcatenator.concatenate(
            normalized,
            output: output,
            container: config.container
        )
        if let final {
            for url in normalized where url != final {
                try? FileManager.default.removeItem(at: url)
            }
            onFinish?(.success(final))
        } else if let first = normalized.first {
            onFinish?(.success(first))
        } else {
            onFinish?(.failure(RecordingError.startFailed("录制失败。")))
        }
    }

    /// Give one segment a single audio track (mix system + mic, or mux the mic).
    private func normalize(_ segment: Segment) async -> URL? {
        guard let mic = segment.mic else { return segment.video }
        var audioURL = mic
        var audioOffset = segment.micOffset
        if config.audio == .systemAndMicrophone {
            let mixed = FileManager.default.temporaryDirectory
                .appendingPathComponent("kacha-mix-\(UUID().uuidString).m4a")
            if let mixedURL = await AudioMixer.mix(
                systemAudio: segment.video,
                microphone: mic,
                offset: segment.micOffset,
                output: mixed
            ) {
                audioURL = mixedURL
                audioOffset = .zero
            } else {
                onWarning?("系统声音与麦克风混音失败，这一段只有麦克风音轨。")
            }
        }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("kacha-seg-\(UUID().uuidString).\(config.container.fileExtension)")
        let muxed = await RecordingMuxer.mux(
            video: segment.video,
            microphone: audioURL,
            offset: audioOffset,
            output: output,
            container: config.container
        )
        if audioURL != mic { try? FileManager.default.removeItem(at: audioURL) }
        try? FileManager.default.removeItem(at: mic)
        return muxed
    }

    private func removeSegments() {
        for segment in segments {
            try? FileManager.default.removeItem(at: segment.video)
            if let mic = segment.mic { try? FileManager.default.removeItem(at: mic) }
        }
        segments = []
    }
}
