import Foundation

/// Everything the JS layer reports, normalized once at the bridge boundary.
/// `raw` keeps events the Swift API does not model yet reachable by the app.
public enum MeetingEvent: Sendable {
    case connectionStatus(ConnectionStatus, message: String?)
    /// The XMPP stream was dropped and lib-jitsi-meet ran out of retries, so the room is
    /// gone. Unlike `connectionInterrupted` (media path only), this needs a fresh connect
    /// and join; the app-level rejoin in `MeetingModel` listens for it.
    case connectionLost(reason: String?)
    /// The current JWT expired while a resume was pending. The lib cancels the resume
    /// unless `refreshToken(_:)` supplies a new one within its 3 second window.
    case tokenExpired(resumable: Bool)
    /// The media path dropped (ICE disconnected). lib-jitsi-meet keeps retrying and joins
    /// the bridge if the peer-to-peer link cannot be restored.
    case connectionInterrupted
    case connectionRestored
    case conferenceJoined(ConferenceName)
    case conferenceLeft(reason: String?)
    case conferenceFailed(JitsiError)
    case participantJoined(ParticipantSnapshot)
    case participantLeft(ParticipantSnapshot)
    case participantDisplayNameChanged(ParticipantID, String)
    /// Presence command `avatar-url`; nil when the participant withdrew it.
    case participantAvatarChanged(ParticipantID, String?)
    /// Presence command `email`; nil when the participant withdrew it.
    case participantEmailChanged(ParticipantID, String?)
    case participantRoleChanged(ParticipantID, ParticipantRole)
    case participantMuted(ParticipantID, MediaType, Bool)
    case dominantSpeakerChanged(ParticipantID?)
    case raisedHandChanged(ParticipantID, Bool)
    case localTrackAdded(TrackSnapshot)
    case localTrackRemoved(TrackSnapshot)
    case remoteTrackAdded(TrackSnapshot, ParticipantID)
    case remoteTrackRemoved(TrackSnapshot, ParticipantID)
    case trackMuteChanged(TrackSnapshot)
    case audioLevels([ParticipantID: Double])
    case connectionQualityLevel(digital: Int, summary: String, participantID: ParticipantID?)
    case endpointMessage(from: ParticipantID?, JSONValue)
    case chatMessage(from: ParticipantID, text: String, isPrivate: Bool)
    case recordingStateChanged(JSONValue)
    case e2EEStateChanged(JSONValue)
    case kick(ParticipantID)
    case raw(name: String, JSONValue)
}
