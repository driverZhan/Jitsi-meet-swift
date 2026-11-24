#if canImport(ReplayKit)
import AVFoundation
import CoreMedia
import Foundation
import JitsiCore
import os
import ReplayKit
import UIKit

/// What the screen recorder writes.
public struct ScreenRecordingConfiguration: Sendable {
    public var outputURL: URL
    /// Video is throttled to this rate; ReplayKit delivers display-rate buffers.
    public var frameRate: Int
    public var videoBitrate: Int
    /// Non-nil mixes the microphone and the remote playout from the injected audio device.
    public var audio: AudioRecordingOptions?

    public init(
        outputURL: URL,
        frameRate: Int = 24,
        videoBitrate: Int = 6_000_000,
        audio: AudioRecordingOptions? = nil
    ) {
        self.outputURL = outputURL
        self.frameRate = frameRate
        self.videoBitrate = videoBitrate
        self.audio = audio
    }
}

/// WYSIWYG recording: ReplayKit captures what the app shows, the injected audio device supplies
/// the audio, and both go into one MP4 in a single pass.
///
/// The video writer is created lazily from the first captured frame because ReplayKit only
/// reveals the screen dimensions on the first buffer (and they change with rotation). Frames
/// are retimed onto a session-local timeline anchored at `start()`; audio shares that anchor,
/// so lip sync does not need a calibration step.
public final class ScreenRecorder {
    private static let log = Logger(subsystem: "org.jitsi.sdk", category: "screen-recording")

    public let configuration: ScreenRecordingConfiguration

    private let videoQueue = DispatchQueue(label: "org.jitsi.sdk.screen-recording.video")
    private let ciContext = CIContext()

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var audioWriter: RecordingAudioWriter?
    private var audioSource: (any AudioTapSource)?
    /// Counts video frames to the next `pcmTap` health check (roughly one per second).
    private var audioTapCheckdown = 0

    private var canvasSize: CGSize = .zero
    private var anchorHostTime: UInt64 = 0
    private var lastVideoOffset: Double = -.infinity
    private var lastVideoPTS: CMTime = .invalid
    /// Frames the writer actually accepted. A file with zero appended frames finishes as an
    /// empty MP4, so `stop()` turns that into an error instead of reporting success.
    private var appendedVideoFrames = 0
    private var lastAppendError: String?
    private var finishing = false
    private var captureStarted = false
    private var hasFinishedFile = false

    public init(configuration: ScreenRecordingConfiguration) {
        self.configuration = configuration
    }

    public var isRecording: Bool { captureStarted && !finishing }

    // MARK: - Lifecycle

    @MainActor
    public func start() async throws {
        guard !captureStarted else { throw LocalRecordingError.alreadyRecording }
        guard configuration.frameRate > 0 else { throw LocalRecordingError.invalidFrameRate }

        let recorder = RPScreenRecorder.shared()
        guard recorder.isAvailable else {
            throw LocalRecordingError.screenCaptureUnavailable
        }
        // We already have the mixed PCM from the audio device; letting ReplayKit add its own
        // microphone/app-audio track would double the audio.
        recorder.isMicrophoneEnabled = false
        recorder.isCameraEnabled = false

        anchorHostTime = HostClock.now
        lastVideoOffset = -.infinity
        lastVideoPTS = .invalid
        finishing = false
        captureStarted = true

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                recorder.startCapture { [weak self] sampleBuffer, type, error in
                    guard let self else { return }
                    if let error {
                        Self.log.error("capture buffer error: \(String(describing: error), privacy: .public)")
                        return
                    }
                    guard type == .video else { return }
                    self.videoQueue.async { self.appendVideo(sampleBuffer) }
                } completionHandler: { error in
                    if let error {
                        continuation.resume(throwing: LocalRecordingError.writerFailed(
                            "screen capture failed: \(error.localizedDescription)"))
                    } else {
                        continuation.resume()
                    }
                }
            }
        } catch {
            captureStarted = false
            throw error
        }
        Self.log.notice("screen recording started")
    }

    @MainActor
    public func stop() async throws -> URL {
        guard captureStarted else { throw LocalRecordingError.notRecording }
        finishing = true

        await stopCapture()

        var failure: Error?
        var frames = 0
        var appendError: String?
        videoQueue.sync {
            detachAudioTap()
            audioWriter?.finish()
            videoInput?.markAsFinished()
            if writer == nil {
                failure = LocalRecordingError.writerFailed("no video frame was captured")
            }
            frames = appendedVideoFrames
            appendError = lastAppendError
        }
        if let failure {
            captureStarted = false
            throw failure
        }

        await finishWritingIfNeeded()
        captureStarted = false
        if let writer, writer.status == .failed {
            throw LocalRecordingError.writerFailed(
                writer.error?.localizedDescription ?? "the screen writer failed")
        }
        guard frames > 0 else {
            throw LocalRecordingError.writerFailed(
                appendError ?? "no video frame was written")
        }
        return configuration.outputURL
    }

    @MainActor
    public func cancel() {
        guard captureStarted else { return }
        finishing = true
        Task { await stopCapture() }
        videoQueue.sync {
            detachAudioTap()
            audioWriter?.cancel()
            writer?.cancelWriting()
        }
        writer = nil
        videoInput = nil
        adaptor = nil
        audioWriter = nil
        captureStarted = false
        try? FileManager.default.removeItem(at: configuration.outputURL)
    }

    // MARK: - Capture

    private func stopCapture() async {
        let recorder = RPScreenRecorder.shared()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            recorder.stopCapture { error in
                if let error {
                    Self.log.error("stopCapture: \(String(describing: error), privacy: .public)")
                }
                continuation.resume()
            }
        }
    }

    private func finishWritingIfNeeded() async {
        guard let writer, !hasFinishedFile else { return }
        hasFinishedFile = true
        await writer.finishWriting()
        if writer.status == .failed {
            Self.log.error("screen recording failed: \(writer.error?.localizedDescription ?? "unknown", privacy: .public)")
        }
    }

    private func detachAudioTap() {
        guard let audioWriter, let audioSource, audioSource.pcmTap === audioWriter else { return }
        audioSource.pcmTap = nil
    }

    /// The audio device drops its tap whenever its unit restarts (ReplayKit's capture start
    /// and interruptions both do that), and the rest of the call has no PCM afterwards unless
    /// the recorder puts itself back. Cheap enough to run off the video callback.
    private func reattachAudioTapIfNeeded() {
        guard let audioWriter, let audioSource, !finishing else { return }
        guard audioSource.pcmTap !== audioWriter else { return }
        audioSource.pcmTap = audioWriter
        NSLog("[screen] audio tap reattached")
        Self.log.notice("screen recording tap reattached after an audio device restart")
    }

    // MARK: - Video

    private func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        guard !finishing, let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let sourceSize = CGSize(
            width: CVPixelBufferGetWidth(imageBuffer),
            height: CVPixelBufferGetHeight(imageBuffer)
        )
        guard sourceSize.width > 0, sourceSize.height > 0 else { return }

        if writer == nil {
            do {
                try makeWriter(size: sourceSize)
            } catch {
                Self.log.error("writer setup failed: \(String(describing: error), privacy: .public)")
                return
            }
        }

        let offset = videoOffset(for: sampleBuffer)
        guard offset >= lastVideoOffset + (1.0 / Double(configuration.frameRate)) * 0.9 else {
            return // throttle to the configured frame rate
        }
        let pts = CMTime(value: Int64(offset * 1_000_000_000), timescale: 1_000_000_000)
        // `CMTimeCompare` treats `.invalid` as NaN, so it cannot be used to seed the first
        // frame; compare only once a real timestamp is on record.
        if lastVideoPTS.isValid, pts <= lastVideoPTS { return }
        if !lastVideoPTS.isValid {
            NSLog("[screen] first frame offset=%.3f size=%dx%d", offset,
                  Int(sourceSize.width), Int(sourceSize.height))
        }
        lastVideoOffset = offset
        lastVideoPTS = pts

        if audioWriter != nil {
            audioTapCheckdown -= 1
            if audioTapCheckdown <= 0 {
                audioTapCheckdown = 15
                reattachAudioTapIfNeeded()
            }
        }

        guard let videoInput, videoInput.isReadyForMoreMediaData else { return }
        if sourceSize == canvasSize {
            // Fast path: retime the captured buffer and append it without touching pixels.
            if let retimed = Self.retimed(sampleBuffer, pts: pts, frameRate: configuration.frameRate) {
                if videoInput.append(retimed) {
                    appendedVideoFrames += 1
                } else {
                    lastAppendError = writer?.error?.localizedDescription ?? "append returned false"
                    Self.log.error("screen append failed: \(self.lastAppendError ?? "", privacy: .public)")
                    NSLog("[screen] append failed: %@", lastAppendError ?? "")
                }
            } else {
                lastAppendError = "retiming the captured buffer failed"
                NSLog("[screen] retime failed at pts %f", offset)
            }
        } else {
            // Rotation changes the buffer size and the writer size is fixed; letterbox instead
            // of dropping the rest of the recording.
            appendLetterboxed(imageBuffer, sourceSize: sourceSize, pts: pts)
        }
    }

    private func appendLetterboxed(_ imageBuffer: CVPixelBuffer, sourceSize: CGSize, pts: CMTime) {
        guard let adaptor, let pool = adaptor.pixelBufferPool else { return }
        var destination: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &destination) == kCVReturnSuccess,
              let destination else { return }

        let scale = min(canvasSize.width / sourceSize.width, canvasSize.height / sourceSize.height)
        let image = CIImage(cvPixelBuffer: imageBuffer)
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let x = (canvasSize.width - image.extent.width) / 2
        let y = (canvasSize.height - image.extent.height) / 2
        ciContext.render(
            image.transformed(by: CGAffineTransform(translationX: x, y: y)),
            to: destination,
            bounds: CGRect(origin: .zero, size: canvasSize),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        adaptor.append(destination, withPresentationTime: pts)
    }

    private func videoOffset(for sampleBuffer: CMSampleBuffer) -> Double {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let anchorNanos = Double(HostClock.nanos(anchorHostTime))
        let retimed = CMTimeConvertScale(pts, timescale: 1_000_000_000, method: .roundHalfAwayFromZero)
        let ptsNanos = Double(HostClock.nanos(UInt64(max(0, retimed.value))))
        if abs(ptsNanos - Double(HostClock.nanos(HostClock.now))) < 3_600 * 1_000_000_000 {
            // ReplayKit timestamps are host time already.
            return max(0, (ptsNanos - anchorNanos) / 1_000_000_000)
        }
        // Unknown domain (some OS builds): fall back to arrival time, which is within one
        // frame of the truth.
        return max(0, (Double(HostClock.nanos(HostClock.now)) - anchorNanos) / 1_000_000_000)
    }

    private func makeWriter(size: CGSize) throws {
        let width = min(4096, max(2, Int(size.width.rounded()) & ~1))
        let height = min(4096, max(2, Int(size.height.rounded()) & ~1))
        canvasSize = CGSize(width: width, height: height)

        try? FileManager.default.removeItem(at: configuration.outputURL)
        let writer = try AVAssetWriter(url: configuration.outputURL, fileType: .mp4)

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: configuration.videoBitrate,
                AVVideoExpectedSourceFrameRateKey: configuration.frameRate,
                AVVideoMaxKeyFrameIntervalKey: configuration.frameRate * 2,
            ],
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw LocalRecordingError.writerFailed("cannot add screen video input")
        }
        writer.add(input)

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )

        // The audio input has to join the writer before `startWriting()`; AVAssetWriter refuses
        // new inputs once it is writing. The tap is only attached after the session starts.
        var recordingAudio: RecordingAudioWriter?
        var tapSource: (any AudioTapSource)?
        if configuration.audio != nil {
            if let source = AudioTapRegistry.source, source.pcmTap == nil {
                do {
                    recordingAudio = try RecordingAudioWriter(
                        writer: writer, startHostTime: anchorHostTime)
                    tapSource = source
                } catch {
                    NSLog("[screen] audio writer failed: %@", String(describing: error))
                }
            } else {
                NSLog("[screen] audio tap unavailable (source=%@, busy=%@)",
                      AudioTapRegistry.source == nil ? "nil" : "ok",
                      AudioTapRegistry.source?.pcmTap == nil ? "no" : "yes")
            }
        }

        guard writer.startWriting() else {
            throw LocalRecordingError.writerFailed(writer.error?.localizedDescription ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: .zero)

        self.writer = writer
        self.videoInput = input
        self.adaptor = adaptor

        if let recordingAudio, let tapSource {
            recordingAudio.start()
            tapSource.pcmTap = recordingAudio
            audioWriter = recordingAudio
            audioSource = tapSource
        }
        NSLog("[screen] writer %dx%d audio=%d status=%ld", width, height,
              self.audioWriter != nil ? 1 : 0, writer.status.rawValue)
        Self.log.notice("screen writer \(width)x\(height) audio=\(self.audioWriter != nil, privacy: .public)")
    }

    private static func retimed(
        _ sampleBuffer: CMSampleBuffer,
        pts: CMTime,
        frameRate: Int
    ) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(frameRate)),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var output: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &output
        )
        return status == noErr ? output : nil
    }
}
#endif
