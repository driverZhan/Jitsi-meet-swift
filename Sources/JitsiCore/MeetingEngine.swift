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
    func setDisplayName(_ name: String) async throws
    func raiseHand(_ raised: Bool) async throws
    func kick(_ participantID: ParticipantID) async throws
    func muteRemote(_ participantID: ParticipantID, mediaType: MediaType, mute: Bool) async throws
    /// Local receive switch: stops this endpoint from receiving any remote audio. It is
    /// not a moderator action and affects nobody else.
    func setRemoteAudioMuted(_ muted: Bool) async throws

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
