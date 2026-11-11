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
    /// Reachability as `NWPathMonitor` sees it. Fed to lib-jitsi-meet for its resume task
    /// and used by the app-level rejoin to hold retries while the radio is down.
    case networkChanged(online: Bool)
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
    /// A `jitsi_participant_*` presence property changed. Matches lib-jitsi-meet's
    /// `PARTICIPANT_PROPERTY_CHANGED` `(participant, name, oldValue, newValue)`.
    case participantPropertyChanged(ParticipantID, key: String, value: JSONValue, previous: JSONValue?)
    /// jicofo's room properties (`audio-limit-reached`, `bridge-count`, visitor counters…).
    /// Not the same as participant properties; the lib reads them with `getProperty(key)`.
    case conferencePropertiesChanged(JSONValue)
    /// XMPP deployment info: `{ region, shard }`, emitted after the connection is established.
    case connectionPropertiesUpdated(JSONValue)
    case dominantSpeakerChanged(ParticipantID?)
    case raisedHandChanged(ParticipantID, Bool)
    /// The room password was set or cleared. The lib reports it as an event only.
    case lockStateChanged(Bool)
    // Lobby
    case lobbyUserJoined(LobbyUser)
    case lobbyUserUpdated(LobbyUser)
    case lobbyUserLeft(ParticipantID)
    case lobbyMessageReceived(from: ParticipantID?, JSONValue)
    // AV moderation
    case avModerationChanged(enabled: Bool, mediaType: AVModerationMediaType?, actor: ParticipantID?)
    /// The local participant was approved to unmute a media type.
    case avModerationApproved(AVModerationMediaType)
    /// The local participant was blocked from unmuting a media type.
    case avModerationRejected(AVModerationMediaType)
    case avModerationParticipantApproved(ParticipantID, AVModerationMediaType)
    case avModerationParticipantRejected(ParticipantID, AVModerationMediaType)
    // Breakout rooms
    /// The component republished the room list (on join and after every change).
    case breakoutRoomsUpdated(BreakoutRoomsState)
    /// A moderator moved this endpoint to `roomJID`; `MeetingModel` follows it by default.
    case breakoutRoomsMoveToRoom(roomJID: String)
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
