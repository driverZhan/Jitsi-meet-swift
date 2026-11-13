import Foundation

/// Everything the JS layer reports, normalized once at the bridge boundary.
/// `raw` keeps events the Swift API does not model yet reachable by the app.
public enum MeetingEvent: Sendable {
    case connectionStatus(ConnectionStatus, message: String?)
    /// The XMPP stream was dropped and lib-jitsi-meet ran out of retries, so the room is
    /// gone. Unlike `connectionInterrupted` (media path only), this needs a fresh connect
    /// and join; the app-level rejoin in `MeetingSession` listens for it.
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
    /// The system output moved: headphones plugged, Bluetooth connected, CarPlay attached…
    /// The value is where audio plays now, not the last route the app requested.
    case audioOutputRouteChanged(AudioOutputRoute)
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
    // Conference metadata and room visibility
    /// The backend's meeting-created timestamp (`CONFERENCE_CREATED_TIMESTAMP`), as sent.
    case conferenceCreatedTimestamp(String)
    /// The MUC join started; `conferenceJoined` follows once the room answers.
    case conferenceJoinInProgress
    /// The deployment's meeting id from disco-info (`CONFERENCE_UNIQUE_ID_SET`).
    case conferenceUniqueIDSet(String)
    /// The conference's first ICE connection. Later media recoveries arrive as
    /// `connectionRestored`; the XMPP status is `connectionStatus`.
    case conferenceConnectionEstablished
    /// Jicofo's `audio-limit-reached` property flipped; true blocks local unmute.
    case audioUnmutePermissionsChanged(Bool)
    /// Jicofo's `video-limit-reached` property flipped; true blocks local unmute.
    case videoUnmutePermissionsChanged(Bool)
    /// Codecs the deployment allows for visitors; empty when the property was removed.
    case visitorCodecsChanged([String])
    /// A participant's bot type changed; nil when it is no longer a bot.
    case botTypeChanged(ParticipantID, String?)
    /// Permissions forced by the backend in the join presence, keyed by permission name.
    case permissionsReceived(JSONValue)
    /// A participant joined without audio, or switched that state.
    case silentStatusChanged(ParticipantID, Bool)
    /// The room became members-only (lobby) or open. `lockStateChanged` is the password
    /// lock; this is the admission policy.
    case membersOnlyChanged(Bool)
    /// The deployment supports visitors, or turned the feature off.
    case visitorsSupportedChanged(Bool)
    /// Dial-in number advertised by the deployment. The lib emits the event without a
    /// value, so the façade reads `conference.getPhoneNumber()`.
    case phoneNumberChanged(String?)
    // File sharing
    case fileSharingFileAdded(JSONValue)
    case fileSharingFileRemoved(String)
    // Visitors signaling
    case visitorsMessage(JSONValue)
    case visitorsRejection
    // Statistics
    /// The bridge's downlink bandwidth estimate in bits per second.
    case bridgeBweStatsReceived(Double)
    /// Stats the bridge sent about `participantID` over the data channel.
    case endpointStatsReceived(ParticipantID, JSONValue)
    /// Outbound RTP stats. The payload is `{ peerConnection, stats }`, with stats keyed by
    /// SSRC, because lib-jitsi-meet hands over its own `TraceablePeerConnection` and a Map.
    case encodeTimeStatsReceived(JSONValue)
    /// Inbound video stats. Same shape as `encodeTimeStatsReceived`.
    case inboundVideoStatsReceived(JSONValue)
    /// Statistics are about to be disposed (conference leaving).
    case beforeStatisticsDisposed
    // Lobby
    /// The members-only refusal carried `<waiting-for-host/>`. Those guests wait in a
    /// persistent lobby and are admitted automatically once an authenticated host starts
    /// the meeting; no moderator approves them from a lobby list.
    case lobbyWaitingForHost(Bool)
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
    /// A moderator moved this endpoint to `roomJID`; `MeetingSession` follows it by default.
    case breakoutRoomsMoveToRoom(roomJID: String)
    case localTrackAdded(TrackSnapshot)
    case localTrackRemoved(TrackSnapshot)
    case remoteTrackAdded(TrackSnapshot, ParticipantID)
    case remoteTrackRemoved(TrackSnapshot, ParticipantID)
    case trackMuteChanged(TrackSnapshot)
    case audioLevels([ParticipantID: Double])
    case connectionQualityLevel(digital: Int, summary: String, participantID: ParticipantID?)
    case endpointMessage(from: ParticipantID?, JSONValue)
    /// A presence command this endpoint subscribed to with `addCommandListener`.
    /// `values` mirrors the lib's presence node: attribute values plus `value`/`children`
    /// when the sender used them.
    case commandReceived(name: String, from: ParticipantID, values: JSONValue)
    case chatMessage(from: ParticipantID, text: String, isPrivate: Bool)
    /// A message the server sent as the room itself rather than as an occupant. The
    /// deployment's time-limit plugin delivers the meeting countdown (`time_restricted`)
    /// through this channel, which is why `from` is nil for it.
    case nonParticipantMessage(from: String?, text: String)
    /// XEP-0459 reaction. `messageID` is empty when it is not attached to a chat message.
    case reactionReceived(participantID: ParticipantID, reactions: [String], messageID: String)
    case recordingStateChanged(JSONValue)
    case e2EEStateChanged(JSONValue)
    case kick(ParticipantID)
    /// This endpoint was kicked from the room. The lib leaves the room right after this
    /// event, so `reason` and `replaced` are what distinguishes a host kick from a
    /// duplicate-JWT replacement.
    case selfKicked(actor: ParticipantID?, reason: String, replaced: Bool)
    /// The server muted a local track (focus command). lib-jitsi-meet has no public event
    /// for this, so the façade re-checks the lib's `isMutedByFocus` flag after the mute.
    /// `isScreenShare` separates the desktop track from the camera.
    case localMutedByFocus(mediaType: MediaType, isScreenShare: Bool, actor: ParticipantID?)
    case raw(name: String, JSONValue)
}
