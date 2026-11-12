import Foundation

/// Everything one meeting needs to start, in one value.
///
/// `capture` defaults to audio + video; pass an empty list for a viewer-only session.
/// `tokenProvider` is called when the server reports the JWT expired during a resume and
/// again before a reconnect builds a fresh connection.
public struct MeetingRequest: Sendable {
    public var connection: ConnectionOptions
    public var conference: ConferenceOptions
    public var capture: [MediaType]
    public var tokenProvider: (@Sendable () async -> String?)?

    public init(
        connection: ConnectionOptions,
        conference: ConferenceOptions,
        capture: [MediaType] = [.audio, .video],
        tokenProvider: (@Sendable () async -> String?)? = nil
    ) {
        self.connection = connection
        self.conference = conference
        self.capture = capture
        self.tokenProvider = tokenProvider
    }
}

/// How admission is being enforced while this endpoint waits outside the room.
public enum LobbyAdmission: Sendable, Equatable {
    /// A moderator has to admit the guest from the lobby list.
    case moderatorApproval
    /// The guest is admitted automatically once an authenticated host starts the meeting.
    case waitingForHost
}

/// Why a session is no longer joined. `endedByHost` and `connectionLost` are reported by the
/// server and the reconnect loop; the other cases are local decisions.
public enum MeetingEndReason: Sendable, Equatable {
    case leftByUser
    case kicked(actor: ParticipantID?, message: String)
    /// Another session authenticated with the same JWT replaced this one.
    case replacedByAnotherSession
    /// The room was destroyed (end-conference component or moderator action).
    case endedByHost(message: String)
    /// The automatic rejoin ran out of attempts.
    case connectionLost
}

/// The single state machine the UI renders. Stages follow the jitsi-meet join order:
/// connect → prejoin (`ready`) → join → lobby/password admission → joined → reconnect → ended.
public enum MeetingPhase: Sendable, Equatable {
    case idle
    /// Installing the engine and opening the XMPP connection.
    case connecting
    /// Connected, conference prepared and local tracks open: the prejoin screen.
    case ready
    /// The MUC join is in flight.
    case joining
    case waitingInLobby(LobbyAdmission)
    case passwordRequired(isRetry: Bool)
    case joined
    case reconnecting(attempt: Int, maxAttempts: Int)
    case ended(MeetingEndReason)
    case failed(message: String)

    /// True while the room is up; a reconnecting session is not joined.
    public var isJoined: Bool {
        if case .joined = self { return true }
        return false
    }

    /// True while a screen other than the room itself should be presented.
    public var isInRoom: Bool {
        if case .joined = self { return true }
        if case .reconnecting = self { return true }
        return false
    }
}

/// Local capture state, shared by the prejoin screen and the in-room controls.
public struct LocalMediaState: Sendable, Equatable {
    public var microphoneMuted: Bool
    public var cameraMuted: Bool
    public var screenSharing: Bool
    public var isFrontCamera: Bool
    public var cameraDeviceID: String?
    public var audioDeviceID: String?

    public init(
        microphoneMuted: Bool = false,
        cameraMuted: Bool = false,
        screenSharing: Bool = false,
        isFrontCamera: Bool = true,
        cameraDeviceID: String? = nil,
        audioDeviceID: String? = nil
    ) {
        self.microphoneMuted = microphoneMuted
        self.cameraMuted = cameraMuted
        self.screenSharing = screenSharing
        self.isFrontCamera = isFrontCamera
        self.cameraDeviceID = cameraDeviceID
        self.audioDeviceID = audioDeviceID
    }
}

/// App-facing lifecycle callbacks. Full lib-jitsi-meet events stay available through
/// `MeetingSession.onConferenceEvent`; this type only carries the transitions an app acts on.
public enum MeetingSessionEvent: Sendable {
    case phaseChanged(MeetingPhase)
    case localMediaChanged(LocalMediaState)
    /// The server muted the local microphone (focus command). `actor` is best-effort:
    /// lib-jitsi-meet clears its actor field as soon as the mute completes.
    case microphoneMutedByHost(actor: ParticipantID?)
    case cameraMutedByHost(actor: ParticipantID?)
    case screenShareMutedByHost(actor: ParticipantID?)
}
