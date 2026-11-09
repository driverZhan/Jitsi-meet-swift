import AVFoundation
import CoreMedia
import CoreVideo
import JitsiCore
import SwiftUI
import UIKit

/// One video rectangle driven by native pixel buffers.
///
/// `AVSampleBufferDisplayLayer` takes the NV12 buffers straight off the media backend, so
/// there is no Metal pipeline to write, no browser process to composite, and no copy into a
/// CGImage per frame.
public struct VideoSurface: UIViewRepresentable {
    private let frames: AsyncStream<VideoPixelFrame>
    private let mirrored: Bool

    public init(frames: AsyncStream<VideoPixelFrame>, mirrored: Bool = false) {
        self.frames = frames
        self.mirrored = mirrored
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    public func makeUIView(context: Context) -> PixelUIView {
        let view = PixelUIView(mirrored: mirrored)
        context.coordinator.start(frames, into: view)
        return view
    }

    public func updateUIView(_ uiView: PixelUIView, context: Context) {
        uiView.mirrored = mirrored
    }

    public static func dismantleUIView(_ uiView: PixelUIView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    public final class Coordinator {
        private var task: Task<Void, Never>?

        fileprivate func start(_ frames: AsyncStream<VideoPixelFrame>, into view: PixelUIView) {
            stop()
            task = Task { [weak view] in
                for await frame in frames {
                    guard !Task.isCancelled else { break }
                    view?.enqueue(frame)
                }
            }
        }

        fileprivate func stop() {
            task?.cancel()
            task = nil
        }
    }
}

/// `UIView` drawing one sample-buffer layer.
///
/// The layer is a sublayer rather than the backing layer because capture hands us
/// landscape buffers plus a rotation flag; rotating a sublayer keeps `UIView`'s own
/// backing-layer frame (and its mirroring transform) untouched.
public final class PixelUIView: UIView {
    private let displayLayer = AVSampleBufferDisplayLayer()
    private var rotation: VideoRotation = .none

    public var mirrored: Bool {
        didSet { transform = mirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity }
    }

    public init(mirrored: Bool) {
        self.mirrored = mirrored
        super.init(frame: .zero)
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspect
        layer.addSublayer(displayLayer)
        if mirrored {
            transform = CGAffineTransform(scaleX: -1, y: 1)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override public func layoutSubviews() {
        super.layoutSubviews()
        layoutDisplayLayer()
    }

    public func enqueue(_ frame: VideoPixelFrame) {
        guard let sample = Self.makeSampleBuffer(from: frame) else { return }
        if frame.rotation != rotation {
            rotation = frame.rotation
            layoutDisplayLayer()
        }
        if displayLayer.status == .failed {
            displayLayer.flush()
        }
        displayLayer.enqueue(sample)
    }

    /// The layer's unrotated bounds are swapped for quarter turns, so `resizeAspect`
    /// fits the portrait tile after the transform is applied.
    private func layoutDisplayLayer() {
        let quarterTurn = rotation == .clockwise || rotation == .counterClockwise
        let size = quarterTurn ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
        displayLayer.bounds = CGRect(origin: .zero, size: size)
        displayLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        displayLayer.setAffineTransform(
            CGAffineTransform(rotationAngle: CGFloat(rotation.rawValue) * .pi / 180)
        )
    }

    /// The layer wants a `CMSampleBuffer`, not a `CVPixelBuffer`, even though nothing is
    /// compressed: the attachment list is what carries the image and the "show now" flag.
    private static func makeSampleBuffer(from frame: VideoPixelFrame) -> CMSampleBuffer? {
        var format: CMFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: frame.pixelBuffer,
            formatDescriptionOut: &format
        ) == noErr, let format else { return nil }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: frame.timestampUs, timescale: 1_000_000),
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: frame.pixelBuffer,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sample
        ) == noErr, let sample else { return nil }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           let first = CFArrayGetValueAtIndex(attachments, 0)
        {
            let dict = unsafeBitCast(first, to: NSMutableDictionary.self)
            dict[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        return sample
    }
}

/// SwiftUI wrapper so app code never constructs the stream itself.
public struct TrackVideo: View {
    private let model: MeetingModel
    private let trackID: TrackID?
    private let mirrored: Bool

    public init(model: MeetingModel, trackID: TrackID?, mirrored: Bool = false) {
        self.model = model
        self.trackID = trackID
        self.mirrored = mirrored
    }

    public var body: some View {
        Group {
            if let trackID {
                VideoSurface(frames: model.frames(for: trackID), mirrored: mirrored)
            } else {
                ZStack {
                    Color(white: 0.12)
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 44))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
