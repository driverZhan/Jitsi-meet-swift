import Foundation

/// The seam between the Swift API and whatever runs the conference.
/// `JitsiJSRuntime` implements it over lib-jitsi-meet on JavaScriptCore; a native
/// implementation can be substituted later without touching the app or the UI layer.
public protocol MeetingEngine: AnyObject {
    var events: AsyncStream<MeetingEvent> { get }
    /// Current transport reachability; also delivered as `.networkChanged`. Engines without
    /// a monitor report online so callers never wait for a signal that cannot arrive.
    var isNetworkOnline: Bool { get }

    func install() async throws
    func dispose() async

    // Connection
    func connect(_ options: ConnectionOptions) async throws
    func disconnect() async
    /// Tears the signalling session down ahead of a rejoin without touching the audio
    /// session. Flapping networks recover in seconds, and deactivating AVAudioSession on
    /// every cycle costs a route change plus an interruption for the user.
    func resetForRejoin() async
    /// Replaces the JWT while lib-jitsi-meet resumes a dropped XMPP stream.
    func refreshToken(_ token: String) async throws

    // Conference lifecycle. One conference at a time: a phone does not need the
    // multi-conference surface lib-jitsi-meet exposes for the browser.
    /// Creates the conference object without joining. Calling it before `openCapture` lets
    /// the local tracks be part of the session answer, which is what lib-jitsi-meet and
    /// jitsi-meet do; skipping it also works because engines may join on demand.
    func prepareConference(_ options: ConferenceOptions) async throws
    /// Joins the room. `waitForJoin` non-nil makes the call return only once the conference
    /// reports joined, which is what a reconnect needs: `join()` alone returns while the MUC
    /// join is still in flight, so a failed rejoin would look successful. The initial join
    /// passes nil because a lobby-protected room never reaches `CONFERENCE_JOINED`.
    func joinConference(_ options: ConferenceOptions, waitForJoin timeout: TimeInterval?) async throws
    func leaveConference() async

    // Media
    func openCapture(_ mediaTypes: [MediaType], deviceIDs: [String: String]) async throws -> [TrackSnapshot]
    func closeCapture(_ trackIDs: [TrackID]) async throws
    func attachTracks(_ trackIDs: [TrackID]) async throws
    func detachTracks(_ trackIDs: [TrackID]) async throws
    func setMuted(_ muted: Bool, mediaType: MediaType) async throws
    /// Asks the bridge for at most `maxHeight` pixels on received video and forwards at most
    /// `lastN` remote videos. This is the main receiver-side lever for CPU and bandwidth in
    /// a multi-party grid.
    func applyReceivePolicy(maxHeight: Int, lastN: Int) async throws
    func setVideoQuality(_ height: Int) async throws
    /// Resolution and frame-rate formats the active camera supports, plus what it is using.
    func videoCapabilities(for trackID: TrackID) async throws -> VideoTrackCapabilities
    /// Changes capture width/height/frame rate in place. The track id is kept, so no
    /// renegotiation happens; only the frames the camera produces change.
    func applyVideoConstraints(_ constraints: VideoConstraints, to trackID: TrackID) async throws
        -> VideoTrackCapabilities
    /// Creates a desktop track backed by the ReplayKit broadcast extension. The track is
    /// returned immediately; frames arrive once the user starts the system broadcast.
    func startScreenShare() async throws -> TrackSnapshot
    func stopScreenShare() async
    /// Switches the live camera between front and back. Returns the new device id.
    /// The existing track id is kept, so no renegotiation is needed.
    func switchCamera() async throws -> String

    /// Video frames for the UI. Exposed here so the rendering layer never has to know
    /// which engine implementation is installed.
    func frameStream(for trackID: TrackID) -> AsyncStream<VideoPixelFrame>

    // Signaling
    func sendMessage(_ text: String, to participantID: ParticipantID?) async throws
    /// Sends a JSON object over the conference's `json-message` extension. Unlike chat text,
    /// object messages are what jitsi-meet clients decode as structured payloads.
    func sendJSONMessage(_ payload: JSONValue, to participantID: ParticipantID?) async throws
    func setDisplayName(_ name: String) async throws
    func raiseHand(_ raised: Bool) async throws
    func kick(_ participantID: ParticipantID) async throws
    func muteRemote(_ participantID: ParticipantID, mediaType: MediaType, mute: Bool) async throws
    /// Local receive switch: stops this endpoint from receiving any remote audio. It is
    /// not a moderator action and affects nobody else.
    func setRemoteAudioMuted(_ muted: Bool) async throws

    // Conference control. These are moderator actions; lib-jitsi-meet sends the request and
    // the server is the authority, so an unauthorised caller fails asynchronously.
    /// Ends the conference for everyone. Throws when the deployment has no end-conference
    /// component, which is what `JitsiConference.canEndConference` reports.
    func endConference() async throws
    /// Sets (or replaces) the room password. Only a moderator may call it.
    func lockConference(password: String) async throws
    func unlockConference() async throws
    func grantOwner(_ participantID: ParticipantID) async throws
    /// Also accepts the local participant id, which is how a moderator resigns.
    func revokeOwner(_ participantID: ParticipantID) async throws
    /// Marks the local participant as having joined without audio.
    func setSilent(_ silent: Bool) async throws
    func setSubject(_ subject: String) async throws
    func setStartMutedPolicy(_ policy: StartMutedPolicy) async throws

    // Local participant properties. These travel in the MUC presence map; the local
    // participant is not in the conference participant list, so the engine owns the mirror.
    func setLocalParticipantProperty(_ name: String, value: JSONValue) async throws
    func removeLocalParticipantProperty(_ name: String) async throws
    func localParticipantProperty(_ name: String) async throws -> JSONValue?

    // Lobby moderation
    func approveLobbyUser(_ participantID: ParticipantID) async throws
    func denyLobbyUser(_ participantID: ParticipantID) async throws
    /// `participantID == nil` sends to every moderator in the lobby.
    func sendLobbyMessage(_ message: JSONValue, to participantID: ParticipantID?) async throws
    /// The id private lobby messages are addressed to; nil when not waiting in a lobby.
    func myLobbyUserID() async throws -> ParticipantID?

    // AV moderation
    func isAVModerationSupported() async throws -> Bool
    func enableAVModeration(_ mediaType: AVModerationMediaType) async throws
    func disableAVModeration(_ mediaType: AVModerationMediaType) async throws
    func approveAVModeration(_ participantID: ParticipantID, mediaType: AVModerationMediaType) async throws
    func rejectAVModeration(_ participantID: ParticipantID, mediaType: AVModerationMediaType) async throws

    // Lobby
    func enableLobby() async throws
    func disableLobby() async throws
    func joinLobby(displayName: String, email: String) async throws
    /// Server-side conference flags: moderator role, lobby support/enabled, visitors.
    func conferenceState() async throws -> JSONValue

    // Sessions
    func startRecording(_ options: RecordingOptions) async throws
    func stopRecording() async throws
    func enableE2EE(key: String, password: String?) async throws
    func disableE2EE() async throws

    // Product layer
    /// False when the deployment has no polls component.
    func pollsSupported() async throws -> Bool
    func createPoll(id: String, question: String, answers: [String]) async throws
    func answerPoll(id: String, answers: [Bool]) async throws

    // Diagnostics
    func statisticsSnapshot() async throws -> JSONValue
    func setDebugSignaling(_ enabled: Bool) async
}

public extension MeetingEngine {
    var isNetworkOnline: Bool { true }

    func resetForRejoin() async {
        await disconnect()
    }

    func joinConference(_ options: ConferenceOptions) async throws {
        try await joinConference(options, waitForJoin: nil)
    }

    func pollsSupported() async throws -> Bool {
        false
    }

    func createPoll(id: String, question: String, answers: [String]) async throws {
        throw JitsiError.unsupported("createPoll")
    }

    func answerPoll(id: String, answers: [Bool]) async throws {
        throw JitsiError.unsupported("answerPoll")
    }

    func applyReceivePolicy(maxHeight: Int, lastN: Int) async throws {
        throw JitsiError.unsupported("applyReceivePolicy")
    }

    func refreshToken(_ token: String) async throws {
        throw JitsiError.unsupported("refreshToken")
    }

    func setVideoQuality(_ height: Int) async throws {
        throw JitsiError.unsupported("setVideoQuality")
    }

    func videoCapabilities(for _: TrackID) async throws -> VideoTrackCapabilities {
        throw JitsiError.unsupported("videoCapabilities")
    }

    func applyVideoConstraints(_: VideoConstraints, to _: TrackID) async throws -> VideoTrackCapabilities {
        throw JitsiError.unsupported("applyVideoConstraints")
    }

    func sendJSONMessage(_: JSONValue, to _: ParticipantID?) async throws {
        throw JitsiError.unsupported("sendJSONMessage")
    }

    func switchCamera() async throws -> String {
        throw JitsiError.unsupported("switchCamera")
    }

    func startScreenShare() async throws -> TrackSnapshot {
        throw JitsiError.unsupported("startScreenShare")
    }

    func stopScreenShare() async {}

    func setRemoteAudioMuted(_ muted: Bool) async throws {
        throw JitsiError.unsupported("setRemoteAudioMuted")
    }

    func endConference() async throws {
        throw JitsiError.unsupported("endConference")
    }

    func lockConference(password: String) async throws {
        throw JitsiError.unsupported("lockConference")
    }

    func unlockConference() async throws {
        throw JitsiError.unsupported("unlockConference")
    }

    func grantOwner(_ participantID: ParticipantID) async throws {
        throw JitsiError.unsupported("grantOwner")
    }

    func revokeOwner(_ participantID: ParticipantID) async throws {
        throw JitsiError.unsupported("revokeOwner")
    }

    func setSilent(_ silent: Bool) async throws {
        throw JitsiError.unsupported("setSilent")
    }

    func setSubject(_ subject: String) async throws {
        throw JitsiError.unsupported("setSubject")
    }

    func setStartMutedPolicy(_ policy: StartMutedPolicy) async throws {
        throw JitsiError.unsupported("setStartMutedPolicy")
    }

    func setLocalParticipantProperty(_ name: String, value: JSONValue) async throws {
        throw JitsiError.unsupported("setLocalParticipantProperty")
    }

    func removeLocalParticipantProperty(_ name: String) async throws {
        throw JitsiError.unsupported("removeLocalParticipantProperty")
    }

    func localParticipantProperty(_ name: String) async throws -> JSONValue? {
        throw JitsiError.unsupported("localParticipantProperty")
    }

    func approveLobbyUser(_ participantID: ParticipantID) async throws {
        throw JitsiError.unsupported("approveLobbyUser")
    }

    func denyLobbyUser(_ participantID: ParticipantID) async throws {
        throw JitsiError.unsupported("denyLobbyUser")
    }

    func sendLobbyMessage(_ message: JSONValue, to participantID: ParticipantID?) async throws {
        throw JitsiError.unsupported("sendLobbyMessage")
    }

    func myLobbyUserID() async throws -> ParticipantID? {
        throw JitsiError.unsupported("myLobbyUserID")
    }

    func isAVModerationSupported() async throws -> Bool {
        false
    }

    func enableAVModeration(_ mediaType: AVModerationMediaType) async throws {
        throw JitsiError.unsupported("enableAVModeration")
    }

    func disableAVModeration(_ mediaType: AVModerationMediaType) async throws {
        throw JitsiError.unsupported("disableAVModeration")
    }

    func approveAVModeration(_ participantID: ParticipantID, mediaType: AVModerationMediaType) async throws {
        throw JitsiError.unsupported("approveAVModeration")
    }

    func rejectAVModeration(_ participantID: ParticipantID, mediaType: AVModerationMediaType) async throws {
        throw JitsiError.unsupported("rejectAVModeration")
    }

    func enableLobby() async throws {
        throw JitsiError.unsupported("enableLobby")
    }

    func disableLobby() async throws {
        throw JitsiError.unsupported("disableLobby")
    }

    func joinLobby(displayName: String, email: String) async throws {
        throw JitsiError.unsupported("joinLobby")
    }

    func conferenceState() async throws -> JSONValue {
        throw JitsiError.unsupported("conferenceState")
    }

    func statisticsSnapshot() async throws -> JSONValue {
        throw JitsiError.unsupported("statisticsSnapshot")
    }

    func setDebugSignaling(_ enabled: Bool) async {}
}
