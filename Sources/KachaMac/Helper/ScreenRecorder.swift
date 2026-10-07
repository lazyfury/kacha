// The recording backend: one SCStream writing to a file via `SCRecordingOutput`.
//
// macOS 15+ only. `SCRecordingOutput` muxes screen + system audio + microphone
// into a single file, so there is no AVAssetWriter plumbing here. The stream
// excludes this app's own windows so the control bar never lands in the video.

import AVFoundation
import CoreMedia
import ScreenCaptureKit

@available(macOS 15.0, *)
@MainActor
final class ScreenRecorder: NSObject {
    private var stream: SCStream?
    private var output: SCRecordingOutput?
    private var url: URL?
    private var cancelled = false
    private var reported = false

    /// Host-clock time when capture started, for aligning a separate microphone.
    private(set) var startedAt: CMTime = .invalid

    /// Called once when the recording ends: `.success` with the written file,
    /// `.failure` on error or when the user cancelled.
    var onFinish: ((Result<URL, Error>) -> Void)?

    /// The elapsed recorded time, for the control bar's timer.
    var elapsed: TimeInterval {
        guard let output else { return 0 }
        let duration = output.recordedDuration
        guard duration.isValid, duration.isNumeric else { return 0 }
        return max(CMTimeGetSeconds(duration), 0)
    }

    /// Start recording `target` into `url`.
    func start(target: RecordingTarget, options: RecordingConfig, to url: URL) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownWindows = content.windows.filter {
            $0.owningApplication?.processID == ownPID
        }
        let (filter, configuration) = try Self.streamConfig(
            for: target,
            options: options,
            content: content,
            excluding: ownWindows
        )

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)

        let outputConfig = SCRecordingOutputConfiguration()
        outputConfig.outputURL = url
        outputConfig.videoCodecType = Self.codec(options.codec)
        outputConfig.outputFileType = Self.fileType(options.container)
        let output = SCRecordingOutput(configuration: outputConfig, delegate: self)
        try stream.addRecordingOutput(output)

        self.stream = stream
        self.output = output
        self.url = url
        startedAt = CMClockGetTime(CMClockGetHostTimeClock())
        try await stream.startCapture()
    }

    /// Stop and keep the file.
    func stop() {
        finish(cancelled: false)
    }

    /// Stop and delete the file.
    func cancel() {
        finish(cancelled: true)
    }

    private func finish(cancelled: Bool) {
        guard stream != nil, !reported else { return }
        self.cancelled = cancelled
        let stream = self.stream
        Task {
            try? await stream?.stopCapture()
        }
    }

    // MARK: - Configuration

    /// The AV codec for a recording codec choice.
    private static func codec(_ codec: RecordingCodec) -> AVVideoCodecType {
        switch codec {
        case .h264: return .h264
        case .hevc: return .hevc
        }
    }

    /// The AV file type for a container choice.
    private static func fileType(_ container: RecordingContainer) -> AVFileType {
        switch container {
        case .mp4: return .mp4
        case .mov: return .mov
        }
    }

    private static func streamConfig(
        for target: RecordingTarget,
        options: RecordingConfig,
        content: SCShareableContent,
        excluding ownWindows: [SCWindow]
    ) throws -> (SCContentFilter, SCStreamConfiguration) {
        let config = SCStreamConfiguration()
        config.minimumFrameInterval = CMTime(
            value: 1,
            timescale: CMTimeScale(options.frameRate.rawValue)
        )
        config.queueDepth = 6
        config.showsCursor = options.showCursor
        config.showMouseClicks = options.showClicks
        config.capturesAudio = options.audio == .system
        config.excludesCurrentProcessAudio = true

        let filter: SCContentFilter
        switch target {
        case .display(let display):
            guard
                let scDisplay = content.displays.first(where: {
                    $0.displayID == display.displayID
                })
            else {
                throw RecordingError.noDisplay
            }
            filter = SCContentFilter(display: scDisplay, excludingWindows: ownWindows)
            let size = recordingDisplaySize(display: display)
            config.width = size.width
            config.height = size.height
        case .region(let display, let selection):
            guard
                let scDisplay = content.displays.first(where: {
                    $0.displayID == display.displayID
                })
            else {
                throw RecordingError.noDisplay
            }
            filter = SCContentFilter(display: scDisplay, excludingWindows: ownWindows)
            let geometry = recordingRegion(selection: selection, display: display)
            config.sourceRect = geometry.sourceRect
            config.width = geometry.width
            config.height = geometry.height
        case .window(let window):
            filter = SCContentFilter(desktopIndependentWindow: window)
            let scale = CGFloat(filter.pointPixelScale)
            let rect = filter.contentRect
            config.width = evenPixelCount(rect.width * scale)
            config.height = evenPixelCount(rect.height * scale)
        }
        return (filter, config)
    }

    // MARK: - Outcome

    private func report(_ result: Result<URL, Error>) {
        guard !reported else { return }
        reported = true
        stream = nil
        output = nil
        url = nil
        onFinish?(result)
    }
}

@available(macOS 15.0, *)
extension ScreenRecorder: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            self.report(.failure(error))
        }
    }
}

@available(macOS 15.0, *)
extension ScreenRecorder: SCRecordingOutputDelegate {
    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {}

    nonisolated func recordingOutput(
        _ recordingOutput: SCRecordingOutput,
        didFailWithError error: Error
    ) {
        Task { @MainActor in
            self.report(.failure(error))
        }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in
            guard let url = self.url else { return }
            if self.cancelled {
                try? FileManager.default.removeItem(at: url)
                self.report(.failure(RecordingError.cancelled))
            } else {
                self.report(.success(url))
            }
        }
    }
}
