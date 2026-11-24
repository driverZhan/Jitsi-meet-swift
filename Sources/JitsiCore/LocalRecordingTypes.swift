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

/// Records the microphone and the mixed remote audio into the file's AAC track.
///
/// This needs the injected `RTCAudioDevice` (`SDKConfig.useCustomAudioDevice`): without it
/// the SDK has no PCM to tap, and `LocalVideoRecorder.start()` fails with
/// `LocalRecordingError.audioTapUnavailable` instead of writing a silent track.
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
    /// Non-nil records a single AAC track mixing the microphone and the remote audio.
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
    /// Audio was requested but no injected audio device is available, or another recorder
    /// already holds its tap.
    case audioTapUnavailable
    /// ReplayKit refused to start (simulator, MDM, or capture blocked).
    case screenCaptureUnavailable
}

extension LocalRecordingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return "A local recording is already running."
        case .notRecording:
            return "No local recording is running."
        case .engineNotInstalled:
            return "The meeting engine is not installed."
        case .invalidCanvasSize:
            return "The recording canvas size must be greater than zero."
        case .invalidFrameRate:
            return "The recording frame rate must be greater than zero."
        case .writerFailed(let message):
            return message
        case .audioTapUnavailable:
            return "Audio recording needs the custom audio device (SDKConfig.useCustomAudioDevice)."
        case .screenCaptureUnavailable:
            return "Screen recording is not available on this device."
        }
    }
}

public enum LocalRecordingState: String, Sendable, Equatable {
    case idle
    case recording
    case finishing
}
