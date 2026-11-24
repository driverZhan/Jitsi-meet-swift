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
    /// Identifies the stream behind `frames`. When it changes (camera → screen share, or a
    /// camera re-published under a new track id) the player restarts on the new stream;
    /// without this the representable keeps draining the old, now silent, one and the tile
    /// stays black.
    private let identity: AnyHashable
    private let mirrored: Bool
    private let fillMode: VideoFillMode

    public init(
        frames: AsyncStream<VideoPixelFrame>,
        identity: AnyHashable = "",
        mirrored: Bool = false,
        fillMode: VideoFillMode = .fit
    ) {
        self.frames = frames
        self.identity = identity
        self.mirrored = mirrored
        self.fillMode = fillMode
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    public func makeUIView(context: Context) -> PixelUIView {
        let view = PixelUIView(mirrored: mirrored, fillMode: fillMode)
        context.coordinator.start(frames, identity: identity, into: view)
        return view
    }

    public func updateUIView(_ uiView: PixelUIView, context: Context) {
        uiView.mirrored = mirrored
        uiView.fillMode = fillMode
        context.coordinator.start(frames, identity: identity, into: uiView)
    }

    public static func dismantleUIView(_ uiView: PixelUIView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    public final class Coordinator {
        private var task: Task<Void, Never>?
        private var identity: AnyHashable?

        fileprivate func start(
            _ frames: AsyncStream<VideoPixelFrame>,
            identity: AnyHashable,
            into view: PixelUIView
        ) {
            guard self.identity != identity else { return }
            self.identity = identity
            stop()
            view.reset()
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

    public var fillMode: VideoFillMode {
        didSet { displayLayer.videoGravity = fillMode == .fill ? .resizeAspectFill : .resizeAspect }
    }

    public init(mirrored: Bool, fillMode: VideoFillMode = .fit) {
        self.mirrored = mirrored
        self.fillMode = fillMode
        super.init(frame: .zero)
        backgroundColor = .black
        displayLayer.videoGravity = fillMode == .fill ? .resizeAspectFill : .resizeAspect
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

    /// Drops the decoded picture and any queued samples. Used when the surface is handed a
    /// different track: keeping the old frame would show the previous camera/share until the
    /// new stream produces its first buffer, and a failed layer would never recover.
    public func reset() {
        if #available(iOS 16.0, *) {
            displayLayer.flushAndRemoveImage()
        } else {
            displayLayer.flush()
        }
        rotation = .none
        layoutDisplayLayer()
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
    private let model: MeetingSession
    private let trackID: TrackID?
    private let mirrored: Bool
    private let fillMode: VideoFillMode
    /// The stream is built once per track instead of on every body pass: an `AsyncStream`
    /// that is never consumed keeps its sink in the media backend forever.
    @State private var surface: Surface?

    private struct Surface {
        let trackID: TrackID
        let frames: AsyncStream<VideoPixelFrame>
    }

    public init(
        model: MeetingSession,
        trackID: TrackID?,
        mirrored: Bool = false,
        fillMode: VideoFillMode = .fit
    ) {
        self.model = model
        self.trackID = trackID
        self.mirrored = mirrored
        self.fillMode = fillMode
    }

    public var body: some View {
        Group {
            if let surface {
                VideoSurface(
                    frames: surface.frames,
                    identity: AnyHashable(surface.trackID),
                    mirrored: mirrored,
                    fillMode: fillMode
                )
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
        .task(id: trackID) {
            guard let trackID else {
                surface = nil
                return
            }
            guard surface?.trackID != trackID else { return }
            surface = Surface(trackID: trackID, frames: model.frames(for: trackID))
        }
    }
}

/// A remote participant's avatar, falling back to initials.
///
/// The URL travels in presence, so it is attacker-controlled: only `http`/`https` is
/// fetched, anything else (`file:`, custom schemes) renders the initials instead.
public struct ParticipantAvatar: View {
    private let name: String
    private let url: URL?
    private let size: CGFloat

    public init(name: String, url: String?, size: CGFloat = 44) {
        self.name = name
        self.size = size
        self.url = url.flatMap { raw in
            guard let parsed = URL(string: raw),
                  let scheme = parsed.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  parsed.host != nil
            else { return nil }
            return parsed
        }
    }

    public var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityLabel(Text(name.isEmpty ? "Participant" : name))
    }

    private var placeholder: some View {
        ZStack {
            Color(white: 0.25)
            Text(initials)
                .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
        }
    }

    private var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.map { String($0.prefix(1)) }
        return letters.isEmpty ? "?" : letters.joined().uppercased()
    }
}
