import Foundation

/// Everything the JS layer reports, normalized once at the bridge boundary.
/// `raw` keeps events the Swift API does not model yet reachable by the app.
public enum MeetingEvent: Sendable {
    case connectionStatus(ConnectionStatus, message: String?)
    case conferenceJoined(ConferenceName)
    case conferenceLeft(reason: String?)
    case conferenceFailed(JitsiError)
    case participantJoined(ParticipantSnapshot)
    case participantLeft(ParticipantSnapshot)
    case participantDisplayNameChanged(ParticipantID, String)
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
