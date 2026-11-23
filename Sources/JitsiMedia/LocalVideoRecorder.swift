import Darwin
import AVFoundation
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import JitsiCore

/// Mach host clock, the same domain as `AudioTimeStamp.mHostTime`. File-scope on purpose:
/// the audio thread reads it, so it must not inherit `@MainActor` from the recorder.
enum HostClock {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static var now: UInt64 { mach_absolute_time() }

    static func nanos(_ hostTime: UInt64) -> UInt64 {
        hostTime &* UInt64(timebase.numer) / UInt64(timebase.denom)
    }

    /// Inverse of `nanos`, used by tests to fabricate timestamps.
    static func hostTime(nanos: UInt64) -> UInt64 {
        nanos &* UInt64(timebase.denom) / UInt64(timebase.numer)
    }
}

/// Composites decoded frames from the media backend into one video file.
///
/// The product owns the layout: `layoutProvider` is called before every output frame and
/// returns the tracks to include with their normalized rectangles. Tracks missing from the
/// layout are not recorded; tracks that appear later get their own frame consumer on the
/// next tick.
///
/// With `LocalRecordingConfiguration.audio` set, the microphone and the remote playout are
/// mixed into one AAC track. That path needs the injected `RTCAudioDevice`
/// (`SDKConfig.useCustomAudioDevice`); without it there is no PCM to tap and `start()` throws
/// instead of silently producing a video-only file.
///
/// Screen sharing and local recording are mutually exclusive in the product (one ReplayKit
/// broadcast session at a time); this recorder does not start or stop a broadcast.
@MainActor
public final class LocalVideoRecorder {
    private let configuration: LocalRecordingConfiguration
    private let layoutProvider: @Sendable () -> [RecordingTile]

    private let frameLock = NSLock()
    private var latestFrames: [TrackID: VideoPixelFrame] = [:]

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var audioWriter: RecordingAudioWriter?
    private var consumerTasks: [TrackID: Task<Void, Never>] = [:]
    private var pumpTask: Task<Void, Never>?
    private var upstream: MeetingEngine?
    private let ciContext = CIContext()
    /// Shared clock for the video pump and the audio mixer.
    private var startHostTime: UInt64 = 0
    private var lastVideoPTS: CMTime = .zero

    public private(set) var state: LocalRecordingState = .idle

    public init(
        configuration: LocalRecordingConfiguration,
        layoutProvider: @escaping @Sendable () -> [RecordingTile]
    ) {
        self.configuration = configuration
        self.layoutProvider = layoutProvider
    }

    // MARK: - Lifecycle

    public func start() async throws {
        guard state == .idle else { throw LocalRecordingError.alreadyRecording }
        guard configuration.canvasSize.width > 0, configuration.canvasSize.height > 0 else {
            throw LocalRecordingError.invalidCanvasSize
        }
        guard configuration.frameRate > 0 else { throw LocalRecordingError.invalidFrameRate }
        guard let engine = JitsiMeet.shared.engine else { throw LocalRecordingError.engineNotInstalled }

        // Resolve the tap before touching the disk: a recorder configured with audio must
        // not leave a video-only file behind when the injected device is missing or busy.
        var audioSource: (any AudioTapSource)?
        if configuration.audio != nil {
            guard let source = AudioTapRegistry.source, source.pcmTap == nil else {
                throw LocalRecordingError.audioTapUnavailable
            }
            audioSource = source
        }

        try? FileManager.default.removeItem(at: configuration.outputURL)

        let startHostTime = HostClock.now
        let writer = try AVAssetWriter(url: configuration.outputURL, fileType: .mp4)
        let codec: AVVideoCodecType = configuration.codec == .h264 ? .h264 : .hevc
        let settings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: Int(configuration.canvasSize.width),
            AVVideoHeightKey: Int(configuration.canvasSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: configuration.videoBitrate,
                AVVideoExpectedSourceFrameRateKey: configuration.frameRate,
                AVVideoMaxKeyFrameIntervalKey: configuration.frameRate * 2,
            ],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(configuration.canvasSize.width),
                kCVPixelBufferHeightKey as String: Int(configuration.canvasSize.height),
            ]
        )
        guard writer.canAdd(input) else {
            throw LocalRecordingError.writerFailed("cannot add video input")
        }
        writer.add(input)

        var recordingAudio: RecordingAudioWriter?
        if configuration.audio != nil {
            recordingAudio = try RecordingAudioWriter(writer: writer, startHostTime: startHostTime)
        }

        guard writer.startWriting() else {
            throw LocalRecordingError.writerFailed(writer.error?.localizedDescription ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: .zero)

        self.writer = writer
        self.videoInput = input
        self.adaptor = adaptor
        self.audioWriter = recordingAudio
        self.upstream = engine
        self.startHostTime = startHostTime
        self.lastVideoPTS = .zero
        frameLock.withLock { latestFrames.removeAll() }
        state = .recording

        if let recordingAudio, let audioSource {
            recordingAudio.start()
            audioSource.pcmTap = recordingAudio
        }

        pumpTask = Task { [weak self] in
            guard let self else { return }
            let intervalNs = 1_000_000_000 / UInt64(max(1, configuration.frameRate))
            let interval = Double(intervalNs) / 1_000_000_000
            var next = Date().addingTimeInterval(interval)
            while !Task.isCancelled {
                self.tick()
                let now = Date()
                if now < next {
                    try? await Task.sleep(nanoseconds: UInt64(max(0, next.timeIntervalSince(now)) * 1_000_000_000))
                }
                next = next.addingTimeInterval(interval)
                if Date() > next { next = Date().addingTimeInterval(interval) }
            }
        }
    }

    /// Finishes the file and returns its URL. Safe to call once; further calls throw.
    public func stop() async throws -> URL {
        guard state == .recording else { throw LocalRecordingError.notRecording }
        state = .finishing

        pumpTask?.cancel()
        pumpTask = nil
        for task in consumerTasks.values { task.cancel() }
        consumerTasks.removeAll()
        upstream = nil

        detachAudioTap()
        audioWriter?.finish()
        videoInput?.markAsFinished()
        let activeWriter = writer
        await activeWriter?.finishWriting()
        if activeWriter?.status == .failed {
            let message = activeWriter?.error?.localizedDescription ?? "unknown writer failure"
            reset()
            throw LocalRecordingError.writerFailed(message)
        }
        reset()
        return configuration.outputURL
    }

    /// Aborts without producing a usable file.
    public func cancel() {
        guard state == .recording else { return }
        state = .idle
        pumpTask?.cancel()
        pumpTask = nil
        for task in consumerTasks.values { task.cancel() }
        consumerTasks.removeAll()
        upstream = nil
        detachAudioTap()
        audioWriter?.cancel()
        writer?.cancelWriting()
        reset()
        try? FileManager.default.removeItem(at: configuration.outputURL)
    }

    private func reset() {
        writer = nil
        videoInput = nil
        adaptor = nil
        audioWriter = nil
        startHostTime = 0
        lastVideoPTS = .zero
        if state != .idle { state = .idle }
    }

    /// Only clears the tap we installed; a second recorder must not lose its own.
    private func detachAudioTap() {
        guard let audioWriter,
              let source = AudioTapRegistry.source,
              source.pcmTap === audioWriter else { return }
        source.pcmTap = nil
    }

    // MARK: - Frame pump

    /// One output frame. Reads the current layout, starts consumers for newly visible tracks,
    /// then composites the newest buffered frame of each tile into a single pixel buffer.
    private func tick() {
        let tiles = layoutProvider()
        for tile in tiles where consumerTasks[tile.trackID] == nil {
            guard let engine = upstream else { continue }
            let stream = engine.frameStream(for: tile.trackID)
            consumerTasks[tile.trackID] = Task { [weak self] in
                for await frame in stream {
                    guard let self else { return }
                    self.frameLock.withLock {
                        self.latestFrames[tile.trackID] = frame
                    }
                }
            }
        }

        guard !tiles.isEmpty, let adaptor else { return }
        guard let pool = adaptor.pixelBufferPool else { return }
        var destination: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &destination) == noErr,
              let destination
        else { return }

        frameLock.lock()
        let snapshot = latestFrames
        frameLock.unlock()

        let canvasSize = configuration.canvasSize
        let bounds = CGRect(origin: .zero, size: canvasSize)
        var canvas = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: bounds)
        for tile in tiles.sorted(by: { $0.zOrder < $1.zOrder }) {
            guard let frame = snapshot[tile.trackID] else { continue }
            let image = Self.place(
                CIImage(cvPixelBuffer: frame.pixelBuffer),
                rotation: frame.rotation,
                in: tile.frame,
                canvas: canvasSize,
                mode: tile.contentMode
            )
            canvas = image.composited(over: canvas)
        }

        ciContext.render(canvas, to: destination)
        // Wall-clock PTS on the same host clock as the audio mixer. Using a nominal frame
        // counter here would drift against the audio track whenever a tick is late.
        let elapsed = max(0, HostClock.nanos(HostClock.now) - HostClock.nanos(startHostTime))
        var pts = CMTime(value: Int64(elapsed), timescale: 1_000_000_000)
        if CMTimeCompare(pts, lastVideoPTS) <= 0 {
            pts = CMTimeAdd(lastVideoPTS, CMTime(value: 1, timescale: CMTimeScale(configuration.frameRate)))
        }
        lastVideoPTS = pts
        adaptor.append(destination, withPresentationTime: pts)
    }

    /// Applies rotation, scales the source into the target rectangle and places it in
    /// Core Image coordinates (origin bottom-left), cropping for `.fill`.
    /// Public so hosts can render the same composite off-screen (e.g. a recording preview).
    public static func place(
        _ image: CIImage,
        rotation: VideoRotation,
        in normalizedFrame: CGRect,
        canvas: CGSize,
        mode: RecordingContentMode
    ) -> CIImage {
        var result = image
        if rotation != .none {
            // VideoRotation is clockwise in a Y-down (UIKit) frame. Core Image is Y-up,
            // where a positive angle is counter-clockwise, so negate to match VideoSurface.
            let angle = -CGFloat(rotation.rawValue) * .pi / 180
            result = result.transformed(by: CGAffineTransform(rotationAngle: angle))
        }
        let source = result.extent
        guard source.width > 0, source.height > 0 else { return result }

        let target = CGRect(
            x: normalizedFrame.minX * canvas.width,
            y: canvas.height - normalizedFrame.maxY * canvas.height,
            width: normalizedFrame.width * canvas.width,
            height: normalizedFrame.height * canvas.height
        )
        let scale = mode == .fit
            ? min(target.width / source.width, target.height / source.height)
            : max(target.width / source.width, target.height / source.height)
        result = result.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let scaled = result.extent
        result = result.transformed(
            by: CGAffineTransform(
                translationX: target.midX - scaled.midX,
                y: target.midY - scaled.midY
            )
        )
        return result.cropped(to: target)
    }
}
