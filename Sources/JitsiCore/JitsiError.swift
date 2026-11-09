import Foundation

public enum JitsiError: Error, Equatable {
    /// No `MeetingEngine` has been attached; call `JitsiMeetSDK.bootstrap`.
    case engineNotInstalled
    case jsRuntimeUnavailable(String)
    case jsEvaluationFailed(String)
    case mediaBackendNotLinked
    case captureDenied(MediaType)
    case noLocalTrack(MediaType)
    case notConnected
    case notInConference
    case timeout(String)
    case remote(String)
    case unsupported(String)

    public var isRetryable: Bool {
        switch self {
        case .notConnected, .timeout: return true
        default: return false
        }
    }
}

extension JitsiError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .engineNotInstalled:
            return "The meeting engine is not installed. Call JitsiMeetSDK.bootstrap() first."
        case .jsRuntimeUnavailable(let detail):
            return "JavaScript runtime unavailable: \(detail)"
        case .jsEvaluationFailed(let detail):
            return "Conference script failed: \(detail)"
        case .mediaBackendNotLinked:
            return "No WebRTC backend is linked into the app."
        case .captureDenied(let mediaType):
            return "Permission denied for \(mediaType == .audio ? "microphone" : "camera") access."
        case .noLocalTrack(let mediaType):
            return "No local \(mediaType == .audio ? "audio" : "video") track is live."
        case .notConnected:
            return "Not connected to the conference server."
        case .notInConference:
            return "Not in a conference."
        case .timeout(let detail):
            return "Timed out: \(detail)"
        case .remote(let detail):
            return "Server reported: \(detail)"
        case .unsupported(let detail):
            return "Not supported: \(detail)"
        }
    }
}
