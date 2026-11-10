import Foundation

public enum LocalTrackState: String, Sendable {
    case pending
    case live
    case muted
    case ended
}

/// Runtime capture constraints. Only the fields a phone camera can change without
/// replacing the track are modelled: the resolution and the frame rate.
public struct VideoConstraints: Sendable, Equatable {
    public var width: Int?
    public var height: Int?
    public var frameRate: Int?

    public init(width: Int? = nil, height: Int? = nil, frameRate: Int? = nil) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
    }
}

/// What the active camera can do, and what it is doing now. The format list is the source
/// the UI can offer as resolution choices; `active*` is what a later `apply` actually picked.
public struct VideoTrackCapabilities: Sendable, Equatable {
    public struct Format: Sendable, Equatable {
        public var width: Int
        public var height: Int
        public var minFrameRate: Double
        public var maxFrameRate: Double

        public init(width: Int, height: Int, minFrameRate: Double, maxFrameRate: Double) {
            self.width = width
            self.height = height
            self.minFrameRate = minFrameRate
            self.maxFrameRate = maxFrameRate
        }
    }

    public var formats: [Format]
    public var activeWidth: Int?
    public var activeHeight: Int?
    public var activeFrameRate: Double?
    public var deviceID: String?

    public init(
        formats: [Format] = [],
        activeWidth: Int? = nil,
        activeHeight: Int? = nil,
        activeFrameRate: Double? = nil,
        deviceID: String? = nil
    ) {
        self.formats = formats
        self.activeWidth = activeWidth
        self.activeHeight = activeHeight
        self.activeFrameRate = activeFrameRate
        self.deviceID = deviceID
    }
}

public struct LocalTrack: Identifiable, Sendable {
    public let id: TrackID
    public let snapshot: TrackSnapshot
    public var state: LocalTrackState

    public var mediaType: MediaType { snapshot.mediaType }
    public var muted: Bool { snapshot.muted }
}

public struct RemoteTrack: Identifiable, Sendable {
    public let snapshot: TrackSnapshot
    public let owner: ParticipantID
    public var muted: Bool

    public var id: TrackID { snapshot.id }
    public var mediaType: MediaType { snapshot.mediaType }
    public var videoType: VideoType { snapshot.videoType }
}

/// Reference type on purpose: participants mutate as presence arrives, and the conference
/// keeps one instance per JID so the UI can diff identity-stable rows. Not `Sendable`;
/// `JitsiConference` confines it to the main actor.
public final class JitsiParticipant: Identifiable {
    public let id: ParticipantID
    public private(set) var snapshot: ParticipantSnapshot

    public var displayName: String { snapshot.displayName }
    public var role: ParticipantRole { snapshot.role }
    public var isModerator: Bool { snapshot.role == .moderator || snapshot.role == .owner }
    public var raisedHand: Bool { snapshot.raisedHand }
    public var avatarURL: String? { snapshot.avatarURL }
    public var email: String? { snapshot.email }

    init(snapshot: ParticipantSnapshot) {
        self.id = snapshot.id
        self.snapshot = snapshot
    }

    func apply(_ updated: ParticipantSnapshot) {
        snapshot = updated
    }
}
