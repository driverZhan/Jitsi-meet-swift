import CoreGraphics
import Foundation

/// How a source frame is fitted into its assigned rectangle on the recording canvas.
public enum RecordingContentMode: String, Sendable, Equatable {
    /// Keep the aspect ratio and letterbox the leftover space.
    case fit
    /// Fill the rectangle and crop the overflow.
    case fill
}

/// Where one video track goes in the recording canvas.
///
/// `frame` is normalized to the canvas: (0, 0) is top-left, (1, 1) bottom-right. Normalized
/// coordinates let the product feed the same layout it uses for its own view regardless of
/// the recording resolution.
public struct RecordingTile: Sendable, Equatable {
    public let trackID: TrackID
    public let frame: CGRect
    /// Higher values are drawn last, so they appear on top.
    public let zOrder: Int
    public let rotation: VideoRotation
    public let contentMode: RecordingContentMode

    public init(
        trackID: TrackID,
        frame: CGRect,
        zOrder: Int = 0,
        rotation: VideoRotation = .none,
        contentMode: RecordingContentMode = .fit
    ) {
        self.trackID = trackID
        self.frame = frame
        self.zOrder = zOrder
        self.rotation = rotation
        self.contentMode = contentMode
    }
}

/// Placeholder for the audio source that phase two will capture through a custom
/// `RTCAudioDevice`. Present so callers can wire configuration now without a breaking
/// change later; the video-only recorder ignores it.
public struct AudioRecordingOptions: Sendable, Equatable {
    public init() {}
}

public struct LocalRecordingConfiguration: Sendable {
    public enum VideoCodec: String, Sendable {
        case h264
        case hevc
    }

    public let outputURL: URL
    /// Pixel size of the composited video, e.g. 1280x720.
    public let canvasSize: CGSize
    public let frameRate: Int
    public let videoBitrate: Int
    public let codec: VideoCodec
    /// Reserved. Has no effect until the audio capture hook lands.
    public let audio: AudioRecordingOptions?

    public init(
        outputURL: URL,
        canvasSize: CGSize = CGSize(width: 1280, height: 720),
        frameRate: Int = 30,
        videoBitrate: Int = 2_000_000,
        codec: VideoCodec = .h264,
        audio: AudioRecordingOptions? = nil
    ) {
        self.outputURL = outputURL
        self.canvasSize = canvasSize
        self.frameRate = frameRate
        self.videoBitrate = videoBitrate
        self.codec = codec
        self.audio = audio
    }
}

public enum LocalRecordingError: Error, Sendable, Equatable {
    case alreadyRecording
    case notRecording
    case engineNotInstalled
    case invalidCanvasSize
    case invalidFrameRate
    case writerFailed(String)
}

public enum LocalRecordingState: String, Sendable, Equatable {
    case idle
    case recording
    case finishing
}
