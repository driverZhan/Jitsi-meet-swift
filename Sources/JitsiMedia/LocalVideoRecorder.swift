import AVFoundation
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import JitsiCore

/// Composites decoded frames from the media backend into one video file.
///
/// The product owns the layout: `layoutProvider` is called before every output frame and
/// returns the tracks to include with their normalized rectangles. Tracks missing from the
/// layout are not recorded; tracks that appear later get their own frame consumer on the
/// next tick. Video only — the audio slot in `LocalRecordingConfiguration` is reserved for
/// the phase-two `RTCAudioDevice` hook.
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
    private var consumerTasks: [TrackID: Task<Void, Never>] = [:]
    private var pumpTask: Task<Void, Never>?
    private var frameIndex: Int64 = 0
    private var upstream: MeetingEngine?
    private let ciContext = CIContext()

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

        try? FileManager.default.removeItem(at: configuration.outputURL)

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

        guard writer.startWriting() else {
            throw LocalRecordingError.writerFailed(writer.error?.localizedDescription ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: .zero)

        self.writer = writer
        self.videoInput = input
        self.adaptor = adaptor
        self.upstream = engine
        self.frameIndex = 0
        frameLock.withLock { latestFrames.removeAll() }
        state = .recording

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
        writer?.cancelWriting()
        reset()
        try? FileManager.default.removeItem(at: configuration.outputURL)
    }

    private func reset() {
        writer = nil
        videoInput = nil
        adaptor = nil
        frameIndex = 0
        if state != .idle { state = .idle }
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
        let pts = CMTime(value: frameIndex, timescale: Int32(configuration.frameRate))
        adaptor.append(destination, withPresentationTime: pts)
        frameIndex += 1
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
