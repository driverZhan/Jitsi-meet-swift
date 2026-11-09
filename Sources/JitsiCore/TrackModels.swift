import Foundation

public enum LocalTrackState: String, Sendable {
    case pending
    case live
    case muted
    case ended
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

    init(snapshot: ParticipantSnapshot) {
        self.id = snapshot.id
        self.snapshot = snapshot
    }

    func apply(_ updated: ParticipantSnapshot) {
        snapshot = updated
    }
}
