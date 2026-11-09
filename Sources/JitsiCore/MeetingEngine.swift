import Foundation

/// The seam between the Swift API and whatever runs the conference.
/// `JitsiJSRuntime` implements it over lib-jitsi-meet on JavaScriptCore; a native
/// implementation can be substituted later without touching the app or the UI layer.
public protocol MeetingEngine: AnyObject {
    var events: AsyncStream<MeetingEvent> { get }

    func install() async throws
    func dispose() async

    // Connection
    func connect(_ options: ConnectionOptions) async throws
    func disconnect() async

    // Conference lifecycle. One conference at a time: a phone does not need the
    // multi-conference surface lib-jitsi-meet exposes for the browser.
    func joinConference(_ options: ConferenceOptions) async throws
    func leaveConference() async

    // Media
    func openCapture(_ mediaTypes: [MediaType], deviceIDs: [String: String]) async throws -> [TrackSnapshot]
    func closeCapture(_ trackIDs: [TrackID]) async throws
    func attachTracks(_ trackIDs: [TrackID]) async throws
    func detachTracks(_ trackIDs: [TrackID]) async throws
    func setMuted(_ muted: Bool, mediaType: MediaType) async throws
    func setVideoQuality(_ height: Int) async throws

    /// Video frames for the UI. Exposed here so the rendering layer never has to know
    /// which engine implementation is installed.
    func frameStream(for trackID: TrackID) -> AsyncStream<VideoPixelFrame>

    // Signaling
    func sendMessage(_ text: String, to participantID: ParticipantID?) async throws
    func setDisplayName(_ name: String) async throws
    func raiseHand(_ raised: Bool) async throws
    func kick(_ participantID: ParticipantID) async throws
    func muteRemote(_ participantID: ParticipantID, mediaType: MediaType, mute: Bool) async throws

    // Sessions
    func startRecording(_ options: RecordingOptions) async throws
    func stopRecording() async throws
    func enableE2EE(key: String, password: String?) async throws
    func disableE2EE() async throws

    // Diagnostics
    func statisticsSnapshot() async throws -> JSONValue
    func setDebugSignaling(_ enabled: Bool) async
}

public extension MeetingEngine {
    func setVideoQuality(_ height: Int) async throws {
        throw JitsiError.unsupported("setVideoQuality")
    }

    func statisticsSnapshot() async throws -> JSONValue {
        throw JitsiError.unsupported("statisticsSnapshot")
    }

    func setDebugSignaling(_ enabled: Bool) async {}
}
