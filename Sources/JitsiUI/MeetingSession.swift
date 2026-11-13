import AVFoundation
import JitsiCore
import JitsiMedia
import SwiftUI

/// Compatibility name for the pre-`MeetingSession` API. Kept as a plain alias so existing
/// integrators compile unchanged; new code should use `MeetingSession`.
public typealias MeetingModel = MeetingSession

/// SwiftUI-facing store for one meeting.
///
/// It owns no protocol logic: state comes from `JitsiConference` snapshots plus the shared
/// event hub, and every control funnels into the engine. The grid therefore renders from
/// plain values and never reaches into the JS runtime.
@MainActor
public final class MeetingSession: ObservableObject {
    /// One participant's renderable state. This is the value a custom layout draws from; the
    /// built-in grid reads the same rows, so swapping the view never loses information.
    public struct Tile: Identifiable, Equatable {
        /// Default tile id of this endpoint. It never collides with a MUC participant id.
        public static let localID: ParticipantID = "local"

        public let id: ParticipantID
        public let displayName: String
        public let videoTrackID: TrackID?
        public let isLocal: Bool
        public let isDominantSpeaker: Bool
        public let raisedHand: Bool
        public let audioMuted: Bool
        public let videoMuted: Bool
        /// 0...1, refreshed by the lib's audio level events (~200 ms). Zero while silent.
        public let audioLevel: Double
        public let connectionQuality: String?
        /// lib-jitsi-meet's 0...100 quality figure for this participant; nil until the first
        /// stats sample. The canvas maps it to good/fair/poor with the reference thresholds.
        public let connectionQualityLevel: Int?
        public let role: ParticipantRole
        public let isModerator: Bool
        public let avatarURL: String?
        public let email: String?

        /// True while this participant is audible right now. A muted microphone can still
        /// carry a stale level from before the mute, so the mute wins.
        public var isSpeaking: Bool {
            !audioMuted && audioLevel >= MeetingSession.speakingThreshold
        }
    }

    /// What changed between two snapshots of the same participant. Audio level changes are
    /// only reported when they cross the speaking threshold, so a meter-driven UI is not
    /// woken up every 200 ms per participant.
    public struct ParticipantChange: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let microphoneMuted = ParticipantChange(rawValue: 1 << 0)
        public static let microphoneUnmuted = ParticipantChange(rawValue: 1 << 1)
        public static let cameraMuted = ParticipantChange(rawValue: 1 << 2)
        public static let cameraUnmuted = ParticipantChange(rawValue: 1 << 3)
        public static let speakingStarted = ParticipantChange(rawValue: 1 << 4)
        public static let speakingStopped = ParticipantChange(rawValue: 1 << 5)
        public static let dominantSpeakerChanged = ParticipantChange(rawValue: 1 << 6)
        public static let raisedHandChanged = ParticipantChange(rawValue: 1 << 7)
        /// A different video track (or none) became live: camera toggled, or a screen share
        /// replaced the camera.
        public static let videoTrackChanged = ParticipantChange(rawValue: 1 << 8)
        /// Display name, avatar, email, role or moderator status changed.
        public static let profileChanged = ParticipantChange(rawValue: 1 << 9)
    }

    /// One remote participant toggled its microphone or camera. Local media changes arrive
    /// through `onEvent(.localMediaChanged)` instead.
    public struct RemoteMediaChange: Sendable, Equatable {
        public let participantID: ParticipantID
        public let displayName: String
        public let mediaType: MediaType
        public let isMuted: Bool
    }

    /// A room-wide moderation switch. Enabling it mutes that media type for everyone and
    /// blocks self-unmute until granted, which is the authoritative "the host muted
    /// everyone" signal.
    public struct AVModerationChange: Sendable, Equatable {
        public let mediaType: AVModerationMediaType
        public let isEnabled: Bool
        public let actorID: ParticipantID?
        public let actorDisplayName: String?
    }

    /// Several remote microphones (or cameras) were muted inside one short window, which is
    /// how the host's "mute everyone" reaches the clients. lib-jitsi-meet has no room-level
    /// event and no actor on remote track mutes, so this is a coalescing heuristic: N people
    /// muting themselves at once can match it too. Use `onRemoteMediaChanged` for exact,
    /// per-participant facts.
    public struct HostMuteAll: Sendable, Equatable {
        public let mediaType: MediaType
        public let participantIDs: [ParticipantID]
    }

    public struct Line: Identifiable, Equatable {
        public let id = UUID()
        public let author: String
        public let text: String
        public let isPrivate: Bool
    }

    public struct Poll: Identifiable, Equatable {
        public let id: String
        public let question: String
        public let answers: [String]
        /// Polls replayed from the server's history arrive before anyone votes.
        public let isHistory: Bool
        /// Votes received since joining, per answer index. The polls component does not
        /// attach a voter identity, so these are tallies rather than per-participant state.
        public var counts: [Int]
        public var hasAnswered: Bool

        public var totalVotes: Int { counts.reduce(0, +) }
    }

    public struct Caption: Identifiable, Equatable {
        public let id: String
        public let speaker: String
        public let text: String
        public let isInterim: Bool
    }

    @Published public private(set) var connectionStatus: ConnectionStatus = .idle
    /// The single state machine the UI renders. Every other admission/lifecycle flag is
    /// derived from it, so a screen never has to combine several booleans.
    @Published public private(set) var phase: MeetingPhase = .idle
    @Published public private(set) var isJoined = false
    /// The participant rows the built-in grid and any custom layout render.
    @Published public private(set) var tiles: [Tile] = []
    /// Per-tile audio levels, 0...1, keyed like `tiles`. Published separately so a custom
    /// meter can redraw without re-diffing the whole participant list.
    @Published public private(set) var audioLevels: [ParticipantID: Double] = [:]
    /// Local capture state, shared by the prejoin screen and the in-room controls.
    @Published public private(set) var localMedia = LocalMediaState()
    /// Output route audio is on now. Headphones, Bluetooth and CarPlay show up here and
    /// keep priority over `setAudioOutputRoute` while they are connected.
    @Published public private(set) var currentAudioOutputRoute: AudioOutputRoute?
    @Published public private(set) var isRecording = false
    @Published public private(set) var isHandRaised = false
    /// True while the room has a password; updated by `LOCK_STATE_CHANGED`.
    @Published public private(set) var isLocked = false
    /// Server-reported flags refreshed on join and after room changes.
    @Published public private(set) var e2eeEnabled = false
    @Published public private(set) var visitorsSupported = false
    /// Presence properties this endpoint published; values keep their JSON shape.
    @Published public private(set) var localParticipantProperties: [String: JSONValue] = [:]
    /// jicofo room properties (limits and visitor counters).
    @Published public private(set) var conferenceProperties: [String: JSONValue] = [:]
    @Published public private(set) var lobbyUsers: [LobbyUser] = []
    @Published public private(set) var avModeration: [AVModerationMediaType: Bool] = [:]
    /// Rooms published by the deployment's `breakout_rooms` component, in its order.
    @Published public private(set) var breakoutRooms: [BreakoutRoom] = []
    @Published public private(set) var breakoutRoomsSupported = false
    @Published public private(set) var canRenameBreakoutRooms = false
    @Published public private(set) var isInBreakoutRoom = false
    /// True while a breakout switch runs; the room is leaving one MUC and joining the other.
    @Published public private(set) var isSwitchingRoom = false
    @Published public private(set) var quality: String?
    /// Per-participant quality figures, keyed like `tiles` (`"local"` for this endpoint).
    /// Fed by the lib's local/remote stats events and used for the canvas badge.
    @Published public private(set) var connectionQualityLevels: [ParticipantID: Int] = [:]
    /// Meeting start anchor and time limit. Updated whenever better information arrives;
    /// `onMeetingTiming` fires once with the snapshot taken after the join handshake.
    @Published public private(set) var meetingTiming: MeetingTiming?
    @Published public private(set) var message: String?
    @Published public private(set) var transcript: [Line] = []
    @Published public private(set) var polls: [Poll] = []
    /// False when the deployment has no Prosody polls component.
    @Published public private(set) var pollsSupported = false
    @Published public private(set) var captions: [Caption] = []
    @Published public private(set) var transcriptionActive = false
    /// Reachability from the engine's path monitor. A reconnect attempt is held while this
    /// is false instead of failing three times against a radio that is still coming back.
    @Published public private(set) var isNetworkOnline = true
    /// CPU, memory, thermal state and first-remote-frame latency; sampling starts on join.
    public let metrics = MeetingMetrics()

    /// App-facing lifecycle callbacks, delivered on the main actor.
    public var onEvent: ((MeetingSessionEvent) -> Void)?
    /// Every lib-jitsi-meet event this session reduces, for apps that need the full feed.
    public var onConferenceEvent: ((MeetingEvent) -> Void)?
    /// A participant became renderable: someone else joined, or this endpoint reached the
    /// room. The row carries everything a custom layout needs, including the local one.
    public var onParticipantJoined: ((Tile) -> Void)?
    /// A participant left, or its tile disappeared because the room ended. The row is the
    /// last snapshot, so its name and avatar are still available for an exit animation.
    public var onParticipantLeft: ((Tile) -> Void)?
    /// A rendered participant changed. `ParticipantChange` says what, so the UI can react
    /// without comparing rows itself.
    public var onParticipantChanged: ((Tile, ParticipantChange) -> Void)?
    /// The un-throttled audio level feed, 0...1, for meters that want every sample. The
    /// same values also land in `audioLevels` and `tiles[].audioLevel`.
    public var onAudioLevel: ((ParticipantID, Double) -> Void)?

    // MARK: - Custom-layout callbacks

    /// A remote participant became renderable. The canvas is a self-updating view the app
    /// can place anywhere; the local participant never appears here. Fires on the same
    /// transition as `onParticipantJoined`; pick one channel per screen.
    public var onRemoteCanvasJoined: ((ParticipantCanvas) -> Void)?
    /// A remote participant left, including every remaining remote when the session hangs up.
    public var onRemoteCanvasLeft: ((ParticipantID) -> Void)?
    /// Appearance used for canvases delivered by `onRemoteCanvasJoined`.
    public var canvasStyle: ParticipantCanvasStyle = ParticipantCanvasStyle()

    /// A remote participant toggled its microphone or camera. Change-only: the initial
    /// state comes with the tile/canvas, not as an event.
    public var onRemoteMediaChanged: ((RemoteMediaChange) -> Void)?
    /// The room-wide moderation switch changed (see `AVModerationChange`).
    public var onAVModerationChanged: ((AVModerationChange) -> Void)?
    /// This endpoint was approved (`true`) or rejected (`false`) for a moderated media type.
    public var onAVModerationSelfChanged: ((AVModerationMediaType, Bool) -> Void)?
    /// Coalesced batch of remote mutes; see `HostMuteAll` for the heuristic's limits.
    public var onHostMuteAll: ((HostMuteAll) -> Void)?

    /// Fires once after joining with the meeting's start anchor and time limit. The sources
    /// (room creation timestamp, `time_restricted` message) arrive during the join
    /// handshake, so the callback waits for both or for two seconds, whichever comes first.
    /// If a source turns up later, `meetingTiming` is refreshed without a second callback.
    public var onMeetingTiming: ((MeetingTiming) -> Void)?

    /// Seconds since the meeting started, anchored on the server clock when available.
    public func elapsedSeconds(at date: Date = Date()) -> TimeInterval? {
        meetingTiming?.elapsed(at: date)
    }

    /// Seconds until the limit; negative past it. Nil when no limit is known.
    public func remainingSeconds(at date: Date = Date()) -> TimeInterval? {
        meetingTiming?.remaining(at: date)
    }

    /// The canvas for a remote participant already in the room (late subscriber path).
    public func canvas(for participantID: ParticipantID, style: ParticipantCanvasStyle? = nil) -> ParticipantCanvas? {
        guard participantID != Tile.localID, tiles.contains(where: { $0.id == participantID }) else {
            return nil
        }
        return ParticipantCanvas(session: self, participantID: participantID, style: style ?? canvasStyle)
    }

    /// The local participant's canvas. It is never delivered through the joined callback.
    public func localCanvas(style: ParticipantCanvasStyle? = nil) -> ParticipantCanvas {
        ParticipantCanvas(session: self, participantID: Tile.localID, style: style ?? canvasStyle)
    }

    public var isAudioMuted: Bool { localMedia.microphoneMuted }
    public var isVideoMuted: Bool { localMedia.cameraMuted }
    public var isScreenSharing: Bool { localMedia.screenSharing }
    /// True while this endpoint knocked in the room's lobby after a members-only join.
    public var isWaitingInLobby: Bool {
        if case .waitingInLobby = phase { return true }
        return false
    }
    /// True when the members-only refusal carried `<waiting-for-host/>`; such a guest is
    /// admitted automatically once an authenticated host starts the meeting.
    public var isWaitingForHost: Bool { phase == .waitingInLobby(.waitingForHost) }
    /// True when the join was refused with `conference.passwordRequired`.
    public var requiresPassword: Bool {
        if case .passwordRequired = phase { return true }
        return false
    }

    /// Local camera track id, for the prejoin preview.
    public var localVideoTrackID: TrackID? {
        conference?.localTracks.values
            .first { $0.mediaType == .video && $0.snapshot.videoType != .desktop }?
            .id
    }

    public var isModerator: Bool { conference?.isModerator ?? false }

    /// False when the deployment has no end-conference component, so the control should hide.
    public var canEndConference: Bool { conference?.canEndConference ?? false }

    /// Policy the room publishes for new joiners; nil until the state snapshot arrives.
    public var startMutedPolicy: StartMutedPolicy? { conference?.startMutedPolicy }

    /// Moderators in the main room can manage rooms; the component rejects everyone else.
    public var canManageBreakoutRooms: Bool { conference?.canManageBreakoutRooms ?? false }

    /// The main room this breakout room belongs to; nil while in the main room.
    public var breakoutMainRoomJID: String? { conference?.breakoutMainRoomJID }

    /// True when `retry()` can start a fresh rejoin: a session exists, the room is not up,
    /// and no automatic attempt, lobby wait or password prompt is running.
    public var canRetryConnection: Bool {
        session != nil && !isJoined && !isWaitingInLobby && !requiresPassword && rejoinTask == nil
    }

    /// Host hook for JWT deployments. lib-jitsi-meet asks for a replacement while a dropped
    /// stream is being resumed and cancels the resume if none arrives within 3 seconds.
    public var tokenProvider: (() async -> String?)?

    public private(set) var conference: JitsiConference?

    /// The request this session was started with, for screens that need the display name or
    /// the room options. Nil before `start`.
    public private(set) var request: MeetingRequest?

    private let discovery = CaptureCoordinator()
    private var hubSubscription: Subscription?
    /// Remote mutes seen inside the current `onHostMuteAll` coalescing window, per media type.
    private var muteBatchWindow: [MediaType: Set<ParticipantID>] = [:]
    private var muteBatchTasks: [MediaType: Task<Void, Never>] = [:]
    private static let muteBatchWindowNanos: UInt64 = 800_000_000
    private static let muteBatchMinimumParticipants = 2
    /// `muc#roominfo_created_timestamp`, milliseconds since epoch.
    private var serverCreatedAt: Date?
    /// `time_restricted` payload: the room's limit and the clock it is measured from.
    private var restrictedLimit: (duration: TimeInterval, startedAt: Date)?
    private var localJoinedAt: Date?
    private var timingDeliveryTask: Task<Void, Never>?
    private var hasDeliveredMeetingTiming = false
    private var appliedReceivePolicy: (maxHeight: Int, lastN: Int)?
    /// Everything `start` was called with, so a dropped connection can be rebuilt without
    /// asking the app again.
    private struct Session {
        let connection: ConnectionOptions
        /// The room the app asked for. A breakout switch points `conference` elsewhere; a
        /// return to the main room or a failed recovery comes back here.
        let mainRoom: ConferenceOptions
        /// The room this endpoint is in right now.
        var conference: ConferenceOptions
        let capture: [MediaType]
    }
    private var session: Session?
    private var rejoinTask: Task<Void, Never>?
    private var lobbyKnockTask: Task<Void, Never>?
    /// One room switch at a time: two MOVE_TO_ROOM events for the same move would otherwise
    /// each leave and join, and the second leave would kill the first join.
    private var switchTask: Task<Void, Never>?
    private var rejoinAttempt = 0
    /// Set once the room has been joined. A lifecycle retry must not restart the initial
    /// join or a lobby wait, where `isJoined` is also false.
    private var hasJoined = false
    /// Set when the scene leaves the foreground. Only a real background round-trip grants a
    /// fresh rejoin quota, so a transient inactive state does not restart anything.
    private var wasBackgrounded = false
    /// Drops that were each followed by a successful rejoin. Upstream resets its retry
    /// counter on success, which is right for a single drop and wrong for a flapping radio:
    /// every recovery hid the next drop behind a 1.5 s retry, so a network that dies every
    /// 30 seconds kept the user in a permanent reconnect loop. This decays only after the
    /// connection stayed up for `stableWindow`.
    private var instability = 0
    private var stabilityTask: Task<Void, Never>?
    /// Last `setQuality` choice, re-applied to the rebuilt senders after a rejoin.
    private var videoQualityHeight: Int?
    /// True once a password has been submitted, so a second refusal asks for a retry.
    private var hasAttemptedPassword = false
    /// The lobby flag arrives before the members-only failure that starts the knock, so it
    /// is staged here and folded into `phase` when the knock actually begins.
    private var lobbyWaitingForHost = false
    /// Upstream's `MAX_CONNECTION_RETRIES`: after three failed rejoins in a row the room is
    /// gone. Successes do not consume this, so a flapping network is not dropped for good.
    private static let maxRejoinAttempts = 3
    private static let stableWindow: TimeInterval = 30
    private static let maxInstability = 4
    /// The lib emits roughly 0–0.4 for normal speech after its 2.5× gain. 0.05 separates
    /// talking from room noise on a phone microphone without flickering.
    public static let speakingThreshold: Double = 0.05
    /// Last delivered rows, for join/leave/change detection.
    private var previousTiles: [ParticipantID: Tile] = [:]
    /// `JitsiConferenceErrors.MEMBERS_ONLY_ERROR` / `CONFERENCE_ACCESS_DENIED`; both arrive
    /// as `CONFERENCE_FAILED` with the error name in the payload.
    private static let membersOnlyError = "conference.connectionError.membersOnly"
    private static let accessDeniedError = "conference.connectionError.accessDenied"
    /// `JitsiConferenceErrors.PASSWORD_REQUIRED`: the room is password-protected and the join
    /// carried no (or a wrong) password. Only the user can supply one, so this is terminal
    /// for the attempt instead of a retry.
    private static let passwordRequiredError = "conference.passwordRequired"
    /// `JitsiConferenceErrors.CONFERENCE_DESTROYED`: a moderator ended the room for everyone.
    private static let conferenceDestroyedError = "conference.destroyed"
    private static let waitingForModeratorMessage = "Waiting for a moderator to let you in…"
    private static let waitingForHostMessage = "Waiting for the host to start the meeting…"
    private static let passwordRequiredMessage = "This room requires a password."

    public init() {}

    deinit {
        hubSubscription?.unsubscribe()
    }

    // MARK: - Session

    /// Connect, prepare the conference and open local tracks, then stop at `.ready`.
    /// This is the prejoin point: nothing has been published to the room yet, the camera is
    /// live for a preview and the user can still change microphones, cameras or mute state.
    public func start(_ request: MeetingRequest) async throws {
        guard let engine = JitsiMeet.shared.engine else {
            let detail = JitsiError.engineNotInstalled.errorDescription ?? "engine not installed"
            message = detail
            setPhase(.failed(message: detail))
            throw JitsiError.engineNotInstalled
        }
        observe()
        tokenProvider = request.tokenProvider
        self.request = request
        session = Session(
            connection: request.connection,
            mainRoom: request.conference,
            conference: request.conference,
            capture: request.capture
        )
        rejoinAttempt = 0
        instability = 0
        hasJoined = false
        wasBackgrounded = false
        hasAttemptedPassword = false
        lobbyWaitingForHost = false
        message = nil
        // A new room starts with no participants, so the previous room's rows must not be
        // diffed against it.
        previousTiles = [:]
        audioLevels = [:]
        currentAudioOutputRoute = nil
        resetMeetingTiming()
        lobbyKnockTask?.cancel()
        lobbyKnockTask = nil
        stabilityTask?.cancel()
        stabilityTask = nil
        // The monitor reports once on start, possibly before anything subscribed.
        isNetworkOnline = engine.isNetworkOnline
        let room = makeRoom(request.conference)

        setPhase(.connecting)
        do {
            try await engine.connect(request.connection)
            // Tracks must exist before the room join: the JVB session-initiate arrives while
            // joining and its answer carries the m-lines for every track already registered.
            // Adding them afterwards leaves the senders empty on the bridge side.
            try await engine.prepareConference(request.conference)
            if !request.capture.isEmpty {
                _ = try await room.capture(request.capture)
                syncLocalMedia(from: room)
            }
            rebuildTiles()
            setPhase(.ready)
        } catch {
            let detail = error.localizedDescription
            message = detail
            setPhase(.failed(message: detail))
            throw error
        }
    }

    /// The pre-`MeetingRequest` entry point: connects, prepares, opens capture and joins.
    /// Failures stay on `message` and `phase` like they did before the split.
    @available(*, deprecated, message: "Use startAndJoin(_:) with a MeetingRequest")
    public func start(
        _ connection: ConnectionOptions,
        conference: ConferenceOptions,
        capture: [MediaType] = [.audio, .video]
    ) async {
        try? await startAndJoin(MeetingRequest(
            connection: connection,
            conference: conference,
            capture: capture
        ))
    }

    /// The one-call form: `start` followed by `join`. A lobby wait or password refusal is a
    /// phase, not an error, so this returns and lets the UI present the matching screen.
    public func startAndJoin(_ request: MeetingRequest) async throws {
        try await start(request)
        guard phase == .ready else { return }
        try await join()
    }

    /// Enters the room from `.ready`, or retries admission with a password.
    public func join(password: String? = nil) async throws {
        guard let session, let engine = JitsiMeet.shared.engine, conference != nil else {
            throw JitsiError.notInConference
        }
        guard phase != .joined else { return }
        // A knocked lobby is admitted by the server; joining again would restart the knock.
        guard !isWaitingInLobby else { return }

        var options = session.conference
        if let password, !password.isEmpty {
            options.password = password
            hasAttemptedPassword = true
        }
        self.session?.conference = options
        message = nil
        setPhase(.joining)
        do {
            try await engine.joinConference(options)
        } catch {
            if !requiresPassword {
                let detail = error.localizedDescription
                message = detail
                setPhase(.failed(message: detail))
            }
            throw error
        }
    }

    /// Answers `.passwordRequired` without rebuilding the connection.
    public func submitPassword(_ password: String) async throws {
        guard requiresPassword else {
            throw JitsiError.invalidArgument("no room password is pending")
        }
        try await join(password: password)
    }

    /// Leaves from any pre-join phase (prejoin, lobby wait, password prompt).
    public func cancelJoin() async {
        await hangUp()
    }

    /// Hangs up. The phase moves to `.ended(.leftByUser)` before the teardown so an
    /// in-flight `CONFERENCE_LEFT` cannot be mistaken for a server-side removal.
    public func hangUp() async {
        if case .ended = phase { return }
        setPhase(.ended(.leftByUser))
        await teardown()
    }

    /// Ends the room for everyone, then hangs up locally.
    public func endMeetingForAll() async throws {
        guard let room = conference else { throw JitsiError.notInConference }
        try await room.end()
        await hangUp()
    }

    /// Compatibility alias for the pre-`hangUp` API.
    @available(*, deprecated, renamed: "hangUp()")
    public func leave() async {
        await hangUp()
    }

    private func teardown() async {
        rejoinTask?.cancel()
        rejoinTask = nil
        switchTask?.cancel()
        switchTask = nil
        isSwitchingRoom = false
        rejoinAttempt = 0
        instability = 0
        hasJoined = false
        wasBackgrounded = false
        hasAttemptedPassword = false
        lobbyWaitingForHost = false
        stabilityTask?.cancel()
        stabilityTask = nil
        lobbyKnockTask?.cancel()
        lobbyKnockTask = nil
        session = nil
        await conference?.leave()
        await JitsiMeet.shared.engine?.disconnect()
        hubSubscription?.unsubscribe()
        hubSubscription = nil
        conference = nil
        isJoined = false
        isHandRaised = false
        isLocked = false
        e2eeEnabled = false
        visitorsSupported = false
        localParticipantProperties = [:]
        conferenceProperties = [:]
        lobbyUsers = []
        avModeration = [:]
        connectionQualityLevels = [:]
        resetMeetingTiming()
        muteBatchTasks.values.forEach { $0.cancel() }
        muteBatchTasks = [:]
        muteBatchWindow = [:]
        breakoutRooms = []
        breakoutRoomsSupported = false
        canRenameBreakoutRooms = false
        isInBreakoutRoom = false
        setLocalMedia(LocalMediaState(isFrontCamera: localMedia.isFrontCamera))
        isRecording = false
        videoQualityHeight = nil
        deliverParticipantChanges([])
        tiles = []
        audioLevels = [:]
        polls = []
        pollsSupported = false
        captions = []
        transcriptionActive = false
    }

    /// Host lifecycle hook. Pass `scenePhase == .active`. Returning from the background
    /// with the room already gone grants a fresh rejoin quota; a healthy call and a session
    /// that never joined (initial join or lobby wait) are left untouched.
    public func setAppActive(_ active: Bool) {
        guard session != nil else {
            wasBackgrounded = false
            return
        }
        guard active else {
            wasBackgrounded = true
            return
        }
        let wasAway = wasBackgrounded
        wasBackgrounded = false
        guard wasAway, hasJoined, !isJoined else { return }
        // A suspended rejoin resumes with the app; only a finished loop needs a new quota.
        guard rejoinTask == nil else { return }
        retry()
    }

    /// Manual recovery for the failures the automatic path deliberately does not retry:
    /// server 5xx, BOSH 499/400 and a Prosody-initiated disconnect. Reuses the rejoin loop,
    /// so the jittered backoff and the fresh-token path still apply.
    public func retry() {
        guard session != nil, !isJoined, !requiresPassword, rejoinTask == nil else { return }
        rejoinAttempt = 0
        message = "Reconnecting…"
        setPhase(.reconnecting(attempt: 1, maxAttempts: Self.maxRejoinAttempts))
        scheduleRejoin()
    }

    /// Compatibility alias for the pre-`retry` API.
    @available(*, deprecated, renamed: "retry()")
    public func retryConnection() {
        retry()
    }

    private func scheduleRejoin() {
        guard session != nil, rejoinTask == nil else { return }
        // The rebuild replaces the conference, so a lobby knock in flight is gone with it.
        lobbyKnockTask?.cancel()
        lobbyKnockTask = nil
        rejoinTask = Task { [weak self] in
            guard let self else { return }
            await self.performRejoin()
            self.rejoinTask = nil
        }
    }

    private func makeRoom(_ options: ConferenceOptions) -> JitsiConference {
        // A rebuilt room starts from scratch; a knock aimed at the previous conference
        // must not keep the waiting overlay up.
        lobbyKnockTask?.cancel()
        lobbyKnockTask = nil
        let room = JitsiConference(options: options)
        conference = room
        // The new peer connection starts with the lib defaults, so the policy has to be
        // pushed again even when the grid size did not change.
        appliedReceivePolicy = nil
        room.onStateChange = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.isLocked = room.isLocked
                self.e2eeEnabled = room.e2eeEnabled
                self.visitorsSupported = room.visitorsSupported
                self.localParticipantProperties = room.localParticipantProperties
                self.conferenceProperties = room.conferenceProperties
                self.lobbyUsers = room.lobbyUsers.values.sorted { $0.id < $1.id }
                self.avModeration = room.avModeration
                self.breakoutRooms = room.breakoutRooms
                self.breakoutRoomsSupported = room.breakoutRoomsSupported
                self.canRenameBreakoutRooms = room.canRenameBreakoutRooms
                self.isInBreakoutRoom = room.isInBreakoutRoom
                self.rebuildTiles()
            }
        }
        return room
    }

    /// Full rejoin, the same recovery a jitsi-meet browser performs on
    /// `CONNECTION_DROPPED`. The lib has already disposed the local tracks, so capture runs
    /// again and the user's mute choices are re-applied to the new tracks.
    private func performRejoin() async {
        guard let session = session, let engine = JitsiMeet.shared.engine else { return }
        while rejoinAttempt < Self.maxRejoinAttempts {
            // An offline radio fails every attempt the same way, so hold the quota until a
            // path exists and then retry at once. Upstream jitsi-meet gates its reconnect on
            // the same network event instead of hammering a dead interface.
            var waitedForNetwork = false
            if !isNetworkOnline {
                message = "Waiting for network…"
                await waitForNetwork()
                guard !Task.isCancelled else { return }
                waitedForNetwork = true
            }
            rejoinAttempt += 1
            setPhase(.reconnecting(attempt: rejoinAttempt, maxAttempts: Self.maxRejoinAttempts))
            if !waitedForNetwork {
                // Jittered backoff: 1.5s–3s for a lone drop, growing with each recent drop
                // so a flapping link is not hammered every couple of seconds.
                let base = 1.5 * Double(max(1, instability))
                let delay = base + Double.random(in: 0...base)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { return }
            }
            message = instability >= 3
                ? "Network unstable, reconnecting… (\(rejoinAttempt)/\(Self.maxRejoinAttempts))"
                : "Reconnecting… (\(rejoinAttempt)/\(Self.maxRejoinAttempts))"

            let room = makeRoom(session.conference)
            let connection = await connectionWithFreshToken(session.connection)
            await engine.resetForRejoin()
            do {
                try await engine.connect(connection)
                try await engine.prepareConference(session.conference)
                if !session.capture.isEmpty {
                    _ = try await room.capture(session.capture)
                    if isAudioMuted { try? await room.setMuted(true, mediaType: .audio) }
                    if isVideoMuted { try? await room.setMuted(true, mediaType: .video) }
                }
                // `join()` returns while the MUC join is still in flight; only the joined
                // event says the room is actually up, and a failure after the fact would
                // otherwise be reported as a successful reconnect.
                try await engine.joinConference(session.conference, waitForJoin: 15)
                // The wait can last up to the join timeout; a leave() in that window must
                // win over restoring state into a room the user already left.
                guard !Task.isCancelled else { return }
                rejoinAttempt = 0
                message = nil
                scheduleStabilityReset()
                await restoreSessionState(room)
                syncLocalMedia(from: room)
                rebuildTiles()
                setPhase(.joined)
                return
            } catch {
                // The room switched to members-only while this endpoint was away. Burning
                // the retry quota would only rebuild the conference and abandon the lobby
                // that `CONFERENCE_FAILED` is about to knock on.
                if Self.isMembersOnlyFailure(error) {
                    return
                }
                message = "Reconnect attempt \(rejoinAttempt) failed: \(error.localizedDescription)"
            }
        }
        // Out of attempts: give the audio session back instead of holding the microphone
        // open in front of a dead connection.
        await engine.disconnect()
        message = "Connection lost. Leave and rejoin to continue."
    }

    /// The wait-for-join wrapper prefixes the lib's error name, so this matches by
    /// containment instead of equality.
    private static func isMembersOnlyFailure(_ error: Error) -> Bool {
        guard let jitsiError = error as? JitsiError, case .remote(let detail) = jitsiError else {
            return false
        }
        return detail.contains(membersOnlyError)
    }

    /// Clears the escalated backoff only once the link has stayed up for a while. Cancelled
    /// by the next drop, so a flapping Wi-Fi keeps its accumulated delay.
    private func scheduleStabilityReset() {
        stabilityTask?.cancel()
        stabilityTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.stableWindow * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.instability = 0
            self.stabilityTask = nil
        }
    }

    /// Polls the path monitor between attempts. Four hundred milliseconds is below what a
    /// user can perceive as a delayed reconnect and keeps this cancellation-safe: a
    /// continuation resumed by an event would leak when `leave()` cancels the task. Capped
    /// at 30s because `.satisfied` follows the internet route, which a restricted LAN can
    /// fail while the signalling host is still reachable.
    private func waitForNetwork() async {
        let deadline = Date().addingTimeInterval(30)
        while !isNetworkOnline && !Task.isCancelled && Date() < deadline {
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
    }

    /// A JWT is usually shorter-lived than a call. Reusing the token from the original join
    /// makes every attempt after it expired fail authentication, and the lib only asks for a
    /// replacement while resuming a live stream, never for a fresh connect.
    private func connectionWithFreshToken(_ connection: ConnectionOptions) async -> ConnectionOptions {
        guard connection.token != nil, let provider = tokenProvider,
              let token = await provider(), !token.isEmpty
        else { return connection }
        var refreshed = connection
        refreshed.token = token
        return refreshed
    }

    /// Room-level state the rebuild does not carry over: presence the user set, the sender
    /// constraint they picked, and a desktop track whose capture the lib disposed.
    private func restoreSessionState(_ room: JitsiConference) async {
        if isHandRaised { try? await room.raiseHand(true) }
        if let height = videoQualityHeight {
            try? await JitsiMeet.shared.engine?.setVideoQuality(height)
        }
        if isScreenSharing {
            do {
                _ = try await room.startScreenShare()
            } catch {
                mutateLocalMedia { $0.screenSharing = false }
                message = "Screen share stopped: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Controls

    /// Mutes or unmutes the live microphone track. Works before the join as well, so the
    /// prejoin screen and the in-room bar share one control.
    public func setAudioMuted(_ muted: Bool) async throws {
        guard let room = conference else { throw JitsiError.notInConference }
        try await room.setMuted(muted, mediaType: .audio)
        syncLocalMedia(from: room)
        rebuildTiles()
    }

    /// Mutes or unmutes the camera track. A muted camera keeps sending black frames at the
    /// lib level, exactly like a browser tab with the camera paused.
    public func setVideoMuted(_ muted: Bool) async throws {
        guard let room = conference else { throw JitsiError.notInConference }
        try await room.setMuted(muted, mediaType: .video)
        syncLocalMedia(from: room)
        rebuildTiles()
    }

    public func toggleAudio() async throws {
        try await setAudioMuted(!isAudioMuted)
    }

    public func toggleVideo() async throws {
        try await setVideoMuted(!isVideoMuted)
    }

    /// Front/back switch on the live capture session; the track id is unchanged, so the
    /// room is not renegotiated.
    public func switchCamera() async throws {
        guard let room = conference else { throw JitsiError.notInConference }
        try await room.switchCamera()
        syncLocalMedia(from: room)
        rebuildTiles()
    }

    /// Creates the desktop track before the user starts the system broadcast; frames begin
    /// flowing as soon as the broadcast extension connects to the App Group socket.
    public func startScreenShare() async throws {
        guard let room = conference else { throw JitsiError.notInConference }
        _ = try await room.startScreenShare()
        syncLocalMedia(from: room)
        rebuildTiles()
    }

    public func stopScreenShare() async {
        guard let room = conference else { return }
        await room.stopScreenShare()
        syncLocalMedia(from: room)
        rebuildTiles()
    }

    /// Fire-and-forget wrapper for UI controls: the failure lands on the banner instead of
    /// returning to the view.
    func runControl(_ action: @escaping @MainActor () async throws -> Void) {
        Task {
            do {
                try await action()
            } catch {
                message = error.localizedDescription
            }
        }
    }

    /// Resolution/frame-rate change that keeps the existing track and sender, so the call is
    /// not renegotiated.
    public func applyVideoConstraints(width: Int? = nil, height: Int? = nil, frameRate: Int? = nil) {
        guard let room = conference else { return }
        Task {
            do {
                _ = try await room.applyVideoConstraints(
                    VideoConstraints(width: width, height: height, frameRate: frameRate))
            } catch {
                message = error.localizedDescription
            }
        }
    }

    /// Camera formats for a resolution picker; nil when no local camera is live.
    public func videoCapabilities() async -> VideoTrackCapabilities? {
        guard let room = conference else { return nil }
        return try? await room.videoCapabilities()
    }

    /// Per-source receiver hints for the current grid layout. Fields left nil keep the
    /// bridge's previous value.
    public func setReceiverConstraints(_ constraints: ReceiverConstraints) {
        guard let room = conference else { return }
        Task {
            do {
                try await room.setReceiverConstraints(constraints)
            } catch {
                message = error.localizedDescription
            }
        }
    }

    /// Requests the built-in output route. Headphones, Bluetooth and CarPlay still win
    /// while connected; watch `onEvent` for the route the system actually picked.
    public func setAudioOutputRoute(_ route: AudioOutputRoute) {
        guard let room = conference else { return }
        Task {
            do {
                try await room.setAudioOutputRoute(route)
                if let current = try? await room.audioOutputRoute() {
                    currentAudioOutputRoute = current
                }
            } catch {
                message = error.localizedDescription
            }
        }
    }

    /// The route audio is on right now, read from the audio session rather than cached.
    public func audioOutputRoute() async -> AudioOutputRoute? {
        guard let room = conference else { return nil }
        return try? await room.audioOutputRoute()
    }

    /// Dominant-speaker timing for the meeting report. Rows for participants that left are
    /// retained by the lib's collector.
    public func speakerStats() async -> [SpeakerStats] {
        guard let room = conference else { return [] }
        return (try? await room.speakerStats()) ?? []
    }

    public func setQuality(_ height: Int) {
        videoQualityHeight = height
        Task {
            do {
                try await JitsiMeet.shared.engine?.setVideoQuality(height)
            } catch {
                message = error.localizedDescription
            }
        }
    }

    /// Writes the `jitsi_participant_raiseHand` presence extension every client reads. The
    /// local user has no participant row of their own, so the state is kept here.
    public func toggleHand() {
        guard let room = conference else { return }
        let next = !isHandRaised
        Task {
            do {
                try await room.raiseHand(next)
                isHandRaised = next
                rebuildTiles()
            } catch {
                message = error.localizedDescription
            }
        }
    }

    public func sendChat(_ text: String) {
        guard let room = conference, !text.isEmpty else { return }
        transcript.append(Line(author: "me", text: text, isPrivate: false))
        Task {
            do {
                try await room.sendChatMessage(text)
            } catch {
                message = error.localizedDescription
            }
        }
    }

    /// Structured payload for jitsi-meet style messages; not added to the local chat transcript
    /// because the UI has no renderer for it.
    public func sendJSONMessage(_ payload: JSONValue, to participantID: ParticipantID? = nil) {
        guard let room = conference else { return }
        Task {
            do {
                try await room.sendJSONMessage(payload, to: participantID)
            } catch {
                message = error.localizedDescription
            }
        }
    }

    /// Asks the server to mute another participant. Only moderators are allowed; the
    /// server rejects everyone else.
    public func muteParticipant(_ participantID: ParticipantID, mediaType: MediaType) {
        guard let room = conference, participantID != "local" else { return }
        Task {
            do {
                try await room.mute(participantID, mediaType: mediaType)
            } catch {
                message = error.localizedDescription
            }
        }
    }

    public func kick(_ participantID: ParticipantID) {
        guard let room = conference, participantID != "local" else { return }
        Task {
            do {
                try await room.kick(participantID)
            } catch {
                message = error.localizedDescription
            }
        }
    }

    // MARK: - Conference control (moderator)

    /// Ends the room for everyone. `canEndConference` tells the UI whether to offer it.
    public func endConference() {
        guard let room = conference else { return }
        Task {
            do {
                try await room.end()
            } catch {
                message = error.localizedDescription
            }
        }
    }

    public func lockRoom(password: String = "") {
        guard let room = conference else { return }
        Task {
            do {
                try await room.lock(password: password)
            } catch {
                message = error.localizedDescription
            }
        }
    }

    public func unlockRoom() {
        guard let room = conference else { return }
        Task {
            do {
                try await room.unlock()
            } catch {
                message = error.localizedDescription
            }
        }
    }

    public func grantModerator(_ participantID: ParticipantID) {
        guard let room = conference, participantID != "local" else { return }
        Task {
            do {
                try await room.grantOwner(participantID)
            } catch {
                message = error.localizedDescription
            }
        }
    }

    public func revokeModerator(_ participantID: ParticipantID) {
        guard let room = conference else { return }
        Task {
            do {
                try await room.revokeOwner(participantID)
            } catch {
                message = error.localizedDescription
            }
        }
    }

    /// Marks the local user as having joined without audio; peers skip the join chime.
    public func setSilent(_ silent: Bool) {
        guard let room = conference else { return }
        Task {
            do {
                try await room.setSilent(silent)
            } catch {
                message = error.localizedDescription
            }
        }
    }

    public func setSubject(_ subject: String) {
        guard let room = conference else { return }
        Task {
            do {
                try await room.setSubject(subject)
            } catch {
                message = error.localizedDescription
            }
        }
    }

    public func setStartMutedPolicy(audio: Bool, video: Bool) {
        guard let room = conference else { return }
        Task {
            do {
                try await room.setStartMutedPolicy(audio: audio, video: video)
            } catch {
                message = error.localizedDescription
            }
        }
    }

    // MARK: - Participant properties

    /// Publishes a `jitsi_participant_<name>` presence property. The value keeps its JSON
    /// shape, so string arrays are not flattened by the lib's string-only getter.
    public func setLocalParticipantProperty(_ name: String, value: JSONValue) {
        guard let room = conference else { return }
        Task {
            do {
                try await room.setLocalParticipantProperty(name, value: value)
            } catch {
                message = error.localizedDescription
            }
        }
    }

    public func removeLocalParticipantProperty(_ name: String) {
        guard let room = conference else { return }
        Task {
            do {
                try await room.removeLocalParticipantProperty(name)
            } catch {
                message = error.localizedDescription
            }
        }
    }

    public func localParticipantProperty(_ name: String) async -> JSONValue? {
        try? await conference?.localParticipantProperty(name)
    }

    // MARK: - Lobby moderation

    public func approveLobbyUser(_ participantID: ParticipantID) {
        guard let room = conference else { return }
        Task {
            do {
                try await room.approveLobbyUser(participantID)
            } catch {
                message = error.localizedDescription
            }
        }
    }

    public func denyLobbyUser(_ participantID: ParticipantID) {
        guard let room = conference else { return }
        Task {
            do {
                try await room.denyLobbyUser(participantID)
            } catch {
                message = error.localizedDescription
            }
        }
    }

    /// Sends a structured lobby message; nil broadcasts to every moderator.
    public func sendLobbyMessage(_ message: JSONValue, to participantID: ParticipantID? = nil) {
        guard let room = conference else { return }
        Task {
            do {
                try await room.sendLobbyMessage(message, to: participantID)
            } catch {
                self.message = error.localizedDescription
            }
        }
    }

    public func myLobbyUserID() async -> ParticipantID? {
        try? await conference?.myLobbyUserID()
    }

    // MARK: - AV moderation

    public func isAVModerationSupported() async -> Bool {
        await conference?.isAVModerationSupported() ?? false
    }

    public func enableAVModeration(_ mediaType: AVModerationMediaType) {
        guard let room = conference else { return }
        Task {
            do {
                try await room.enableAVModeration(mediaType)
            } catch {
                message = error.localizedDescription
            }
        }
    }

    public func disableAVModeration(_ mediaType: AVModerationMediaType) {
        guard let room = conference else { return }
        Task {
            do {
                try await room.disableAVModeration(mediaType)
            } catch {
                message = error.localizedDescription
            }
        }
    }

    public func approveAVModeration(_ participantID: ParticipantID, mediaType: AVModerationMediaType) {
        guard let room = conference else { return }
        Task {
            do {
                try await room.approveAVModeration(participantID, mediaType: mediaType)
            } catch {
                message = error.localizedDescription
            }
        }
    }

    public func rejectAVModeration(_ participantID: ParticipantID, mediaType: AVModerationMediaType) {
        guard let room = conference else { return }
        Task {
            do {
                try await room.rejectAVModeration(participantID, mediaType: mediaType)
            } catch {
                message = error.localizedDescription
            }
        }
    }

    public func isAVModerationEnabled(_ mediaType: AVModerationMediaType) -> Bool {
        avModeration[mediaType] ?? false
    }

    // MARK: - Breakout rooms

    /// Re-reads the room list and capability flags before showing a moderator UI.
    public func refreshBreakoutRooms() async {
        await conference?.refreshBreakoutRooms()
    }

    public func createBreakoutRoom(_ subject: String) {
        guard let room = conference else { return }
        Task {
            do {
                try await room.createBreakoutRoom(subject: subject)
            } catch {
                message = error.localizedDescription
            }
        }
    }

    public func renameBreakoutRoom(_ roomJID: String, subject: String) {
        guard let room = conference else { return }
        Task {
            do {
                try await room.renameBreakoutRoom(roomJID, subject: subject)
            } catch {
                message = error.localizedDescription
            }
        }
    }

    public func removeBreakoutRoom(_ roomJID: String) {
        guard let room = conference else { return }
        Task {
            do {
                try await room.removeBreakoutRoom(roomJID)
            } catch {
                message = error.localizedDescription
            }
        }
    }

    public func sendParticipant(_ participantID: ParticipantID, toBreakoutRoom roomJID: String) {
        guard let room = conference else { return }
        Task {
            do {
                try await room.sendParticipant(participantID, toBreakoutRoom: roomJID)
            } catch {
                message = error.localizedDescription
            }
        }
    }

    /// Local switch into a breakout room, matching jitsi-meet's `moveToRoom`: leave with
    /// `switch_room`, then join the target on the same connection.
    public func switchToBreakoutRoom(_ roomJID: String) {
        switchToRoom(atJID: roomJID)
    }

    /// "Leave breakout" is the same switch addressed at the room the app originally joined.
    public func returnToMainRoom() {
        guard let session else { return }
        performSwitch(to: session.mainRoom)
    }

    /// The target options for a room JID. Breakout rooms live on the component's own MUC,
    /// so the JID is split into name + custom domain; a JID on the main room's domain maps
    /// back to the options the app passed to `start`.
    private func options(for roomJID: String) -> ConferenceOptions? {
        guard let session else { return nil }
        let mainDomain = session.mainRoom.configOverwrite["customDomain"]?.stringValue
            ?? session.connection.hosts.muc
        if roomJID.hasSuffix("@" + mainDomain) {
            return session.mainRoom
        }
        return try? session.mainRoom.room(atJID: roomJID)
    }

    private var currentRoomJID: String? {
        guard let session else { return nil }
        let domain = session.conference.configOverwrite["customDomain"]?.stringValue
            ?? session.connection.hosts.muc
        return "\(session.conference.name)@\(domain)"
    }

    private func switchToRoom(atJID roomJID: String) {
        guard !roomJID.isEmpty, roomJID != currentRoomJID else { return }
        guard let options = options(for: roomJID) else {
            message = "Unknown room: \(roomJID)"
            return
        }
        performSwitch(to: options)
    }

    private func performSwitch(to options: ConferenceOptions) {
        guard session != nil, let room = conference, switchTask == nil else { return }
        isSwitchingRoom = true
        switchTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.switchTask = nil
                self.isSwitchingRoom = false
            }
            // Point the session at the target first: if the switch fails after the old room
            // was left, the rejoin path must recover into the room the user was sent to.
            self.session?.conference = options
            do {
                try await room.switchRoom(to: options)
                guard !Task.isCancelled else { return }
                // The new room starts from fresh presence, so the user's mute choices are
                // re-applied to the tracks that were carried over.
                if self.isAudioMuted { try? await room.setMuted(true, mediaType: .audio) }
                if self.isVideoMuted { try? await room.setMuted(true, mediaType: .video) }
                await self.restoreSessionState(room)
                self.hasJoined = true
                self.rebuildTiles()
            } catch {
                guard !Task.isCancelled else { return }
                self.message = "Room switch failed: \(error.localizedDescription)"
                self.scheduleRejoin()
            }
        }
    }

    public func createPoll(question: String, answers: [String]) {
        guard let room = conference else { return }
        Task {
            do {
                try await room.createPoll(question: question, answers: answers)
            } catch {
                message = error.localizedDescription
            }
        }
    }

    public func answerPoll(_ pollID: String, selections: [Bool]) {
        guard let room = conference else { return }
        if let index = polls.firstIndex(where: { $0.id == pollID }) {
            polls[index].hasAnswered = true
        }
        Task {
            do {
                try await room.answerPoll(pollID, answers: selections)
            } catch {
                message = error.localizedDescription
            }
        }
    }

    /// Cameras and microphones, for a device picker.
    public func devices() -> [DeviceDescriptor] {
        discovery.enumerate()
    }

    /// Frames for one track. Each surface gets its own stream, and the backend fan-out
    /// keeps only the newest frame per track.
    public func frames(for trackID: TrackID) -> AsyncStream<VideoPixelFrame> {
        guard let engine = JitsiMeet.shared.engine else {
            return AsyncStream<VideoPixelFrame> { $0.finish() }
        }
        let upstream = engine.frameStream(for: trackID)
        guard conference?.remoteTracks[trackID] != nil else {
            return upstream
        }
        // Remote tiles are the ones worth timing: the first decoded frame is what the user
        // perceives as "the call started". The wrapper only measures the first one.
        return AsyncStream { continuation in
            let task = Task { [metrics] in
                var recorded = false
                for await frame in upstream {
                    if !recorded {
                        recorded = true
                        metrics.markRemoteVideoFrame()
                    }
                    continuation.yield(frame)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Reduction

    private func observe() {
        hubSubscription?.unsubscribe()
        hubSubscription = JitsiMeet.shared.events.subscribe { [weak self] event in
            Task { @MainActor in self?.apply(event) }
        }
    }

    private func apply(_ event: MeetingEvent) {
        switch event {
        case .connectionStatus(let status, let detail):
            connectionStatus = status
            if let detail { message = detail }
        case .conferenceJoined:
            hasJoined = true
            message = nil
            metrics.markJoined()
            metrics.start()
            syncLocalMedia(from: conference)
            loadPollsSupport()
            rebuildTiles()
            setPhase(.joined)
            if localJoinedAt == nil { localJoinedAt = Date() }
            recomputeMeetingTiming()
            scheduleMeetingTimingDelivery()
        case .conferenceLeft(let reason):
            metrics.stop()
            currentAudioOutputRoute = nil
            // A hang-up, a switch and a rejoin each leave the old MUC on purpose; only a
            // leave the session did not ask for is terminal.
            if case .ended = phase { return }
            if isSwitchingRoom || rejoinTask != nil { return }
            if case .reconnecting = phase { return }
            message = reason
            setPhase(.ended(hasJoined ? .connectionLost : .leftByUser))
        case .lobbyWaitingForHost(let waiting):
            lobbyWaitingForHost = waiting
            // The façade reports the flag before the failure, but a knock that resolved
            // first still gets the right wording when the flag arrives second.
            if isWaitingInLobby {
                let admission = waiting ? LobbyAdmission.waitingForHost : .moderatorApproval
                setPhase(.waitingInLobby(admission))
                message = waiting ? Self.waitingForHostMessage : Self.waitingForModeratorMessage
            }
        case .conferenceFailed(let error):
            metrics.stop()
            if case .remote(let name) = error, name == Self.membersOnlyError {
                knockOnLobby()
            } else if case .remote(let name) = error, name == Self.accessDeniedError,
                      isWaitingInLobby {
                let detail = "A moderator denied your request to join."
                message = detail
                setPhase(.failed(message: detail))
            } else if case .remote(let name) = error, name == Self.passwordRequiredError {
                message = Self.passwordRequiredMessage
                setPhase(.passwordRequired(isRetry: hasAttemptedPassword))
            } else if case .remote(let name) = error, name == Self.conferenceDestroyedError {
                let detail = "The meeting has ended."
                message = detail
                setPhase(.ended(.endedByHost(message: detail)))
            } else {
                // The rejoin loop retries these itself; letting the failure overwrite the
                // phase would replace the attempt counter with a terminal screen.
                if case .reconnecting = phase { return }
                let detail = error.localizedDescription
                message = detail
                setPhase(.failed(message: detail))
            }
        case .selfKicked(let actor, let reason, let replaced):
            metrics.stop()
            let endReason: MeetingEndReason = replaced
                ? .replacedByAnotherSession
                : .kicked(actor: actor, message: reason)
            message = nil
            setPhase(.ended(endReason))
            Task { [weak self] in await self?.teardown() }
        case .localMutedByFocus(let mediaType, let isScreenShare, let actor):
            if mediaType == .audio {
                mutateLocalMedia { $0.microphoneMuted = true }
                message = "A moderator muted your microphone."
                onEvent?(.microphoneMutedByHost(actor: actor))
            } else if isScreenShare {
                mutateLocalMedia { $0.screenSharing = false }
                message = "A moderator stopped your screen share."
                onEvent?(.screenShareMutedByHost(actor: actor))
            } else {
                mutateLocalMedia { $0.cameraMuted = true }
                message = "A moderator stopped your camera."
                onEvent?(.cameraMutedByHost(actor: actor))
            }
            rebuildTiles()
        case .avModerationChanged(let enabled, let mediaType, let actor):
            guard let mediaType else { break }
            onAVModerationChanged?(AVModerationChange(
                mediaType: mediaType,
                isEnabled: enabled,
                actorID: actor,
                actorDisplayName: actor.flatMap { actorName(for: $0) }
            ))
        case .avModerationApproved(let mediaType):
            onAVModerationSelfChanged?(mediaType, true)
        case .avModerationRejected(let mediaType):
            onAVModerationSelfChanged?(mediaType, false)
        case .trackMuteChanged(let snapshot):
            // `JitsiConference` already recomputed the participant's mute flags. A local
            // track additionally drives the prejoin/control-bar state.
            if conference?.localTracks[snapshot.id] != nil {
                syncLocalMedia(from: conference)
            }
            rebuildTiles()
        case .conferenceCreatedTimestamp(let raw):
            // Milliseconds since epoch, as the backend's disco#info field carries it.
            if let milliseconds = Double(raw), milliseconds > 0 {
                serverCreatedAt = Date(timeIntervalSince1970: milliseconds / 1000)
                recomputeMeetingTiming()
                if !hasDeliveredMeetingTiming, hasCompleteTimingSources {
                    deliverMeetingTiming()
                }
            }
        case .nonParticipantMessage(let from, let text):
            // Only the room itself may set the limit; a participant echoing this payload is
            // rejected the same way the reference client does (room JID has no resource).
            guard from?.isEmpty ?? true,
                  let limit = Self.parseTimeRestricted(text)
            else { break }
            restrictedLimit = (limit.duration, Date().addingTimeInterval(-limit.elapsed))
            recomputeMeetingTiming()
            if !hasDeliveredMeetingTiming, hasCompleteTimingSources {
                deliverMeetingTiming()
            }
        case .connectionInterrupted:
            message = "Media connection interrupted — reconnecting…"
        case .connectionRestored:
            if message == "Media connection interrupted — reconnecting…" {
                message = nil
            }
        case .networkChanged(let online):
            isNetworkOnline = online
        case .audioOutputRouteChanged(let route):
            currentAudioOutputRoute = route
            onEvent?(.audioOutputRouteChanged(route))
        case .breakoutRoomsUpdated:
            // `JitsiConference` mirrors the list and notifies through `onStateChange`.
            break
        case .breakoutRoomsMoveToRoom(let roomJID):
            // Upstream default: a moderator's move is honored without asking the user.
            switchToRoom(atJID: roomJID)
        case .lockStateChanged(let locked):
            isLocked = locked
        case .connectionLost:
            guard session != nil, !isSwitchingRoom else { return }
            if case .ended = phase { return }
            // The recovery loop owns the phase while it runs; a second drop in that window
            // would only reset the attempt counter it is displaying.
            guard rejoinTask == nil else { return }
            metrics.stop()
            // A rejoin that only survived a few seconds does not make the network healthy,
            // so the backoff keeps escalating until the link proves itself stable.
            stabilityTask?.cancel()
            stabilityTask = nil
            instability = min(instability + 1, Self.maxInstability)
            setPhase(.reconnecting(
                attempt: max(1, rejoinAttempt),
                maxAttempts: Self.maxRejoinAttempts
            ))
            scheduleRejoin()
        case .tokenExpired:
            // Without a host-supplied token the pending resume is cancelled by the lib and
            // the connection drops, which then triggers the rejoin above.
            if let provider = tokenProvider {
                Task {
                    guard let token = await provider(), !token.isEmpty else { return }
                    try? await JitsiMeet.shared.engine?.refreshToken(token)
                }
            } else {
                message = "Session token expired"
            }
        case .chatMessage(let from, let text, let isPrivate):
            transcript.append(Line(author: from, text: text, isPrivate: isPrivate))
        case .endpointMessage(let from, let content):
            applyCaption(from: from, content: content)
        case .recordingStateChanged(let payload):
            if case .string(let status) = payload["status"] {
                isRecording = status == "on" || status == "processing"
            }
        case .connectionQualityLevel(let digital, let summary, let participantID):
            // Local stats arrive without an id; remote stats carry the owner's MUC id.
            let key = participantID ?? Tile.localID
            if digital >= 0 {
                connectionQualityLevels[key] = digital
            }
            if participantID == nil {
                quality = summary.isEmpty ? "level \(digital)" : summary
            }
        case .audioLevels(let latest):
            applyAudioLevels(latest)
        case .raw(let name, let payload):
            applyRaw(name, payload)
        default:
            break
        }
    }

    /// Knocks in the room's lobby after a members-only failure. lib-jitsi-meet treats the
    /// refusal as recoverable and the lobby approval joins the main room on its own, so
    /// `CONFERENCE_JOINED` is what clears the waiting state; no second join is issued here.
    /// A wait-for-host lobby has no approval step, so its message must not promise one.
    private func knockOnLobby() {
        guard !isWaitingInLobby, let session, let room = conference else { return }
        let admission: LobbyAdmission = lobbyWaitingForHost ? .waitingForHost : .moderatorApproval
        setPhase(.waitingInLobby(admission))
        message = lobbyWaitingForHost ? Self.waitingForHostMessage : Self.waitingForModeratorMessage
        let displayName = session.mainRoom.userInfo.displayName
        let email = session.mainRoom.userInfo.email ?? ""
        lobbyKnockTask = Task { [weak self] in
            guard let self else { return }
            defer { self.lobbyKnockTask = nil }
            do {
                try await room.joinLobby(displayName: displayName, email: email)
            } catch {
                guard !Task.isCancelled else { return }
                let detail = error.localizedDescription
                self.message = detail
                self.setPhase(.failed(message: detail))
            }
        }
    }

    private func loadPollsSupport() {
        guard let room = conference else { return }
        Task {
            pollsSupported = await room.pollsSupported()
        }
    }

    private func applyRaw(_ name: String, _ payload: JSONValue) {
        switch name {
        case "pollReceived":
            guard let id = payload["pollId"]?.stringValue,
                  let question = payload["question"]?.stringValue,
                  !polls.contains(where: { $0.id == id }) else { return }
            let answers = payload["answers"]?.arrayValue
                .compactMap { $0.stringValue ?? $0["name"]?.stringValue } ?? []
            guard !answers.isEmpty else { return }
            polls.append(Poll(
                id: id,
                question: question,
                answers: answers,
                isHistory: payload["history"]?.boolValue ?? false,
                counts: Array(repeating: 0, count: answers.count),
                hasAnswered: false
            ))
        case "pollAnswerReceived":
            guard let id = payload["pollId"]?.stringValue,
                  let index = polls.firstIndex(where: { $0.id == id }) else { return }
            let votes = payload["answers"]?.arrayValue.compactMap(\.boolValue) ?? []
            guard votes.count == polls[index].counts.count else { return }
            for (answer, voted) in votes.enumerated() where voted {
                polls[index].counts[answer] += 1
            }
        case "transcriptionStatus":
            transcriptionActive = payload["status"]?.stringValue == "ON"
        default:
            break
        }
    }

    /// Live captions travel as endpoint messages whose `type` says transcription or
    /// translation. Interim results reuse the message id, so the row is replaced rather
    /// than duplicated when the final text lands.
    private func applyCaption(from: ParticipantID?, content: JSONValue) {
        guard let type = content["type"]?.stringValue,
              type == "transcription-result" || type == "translation-result" else { return }
        let text = type == "translation-result"
            ? content["translatedText"]?.stringValue
            : content["transcript"]?.arrayValue.first?["text"]?.stringValue
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let speaker = content["participant"]?["name"]?.stringValue ?? from ?? "?"
        let isInterim = content["is_interim"]?.boolValue ?? false
        let id = content["message_id"]?.stringValue ?? "\(speaker)-interim"
        upsertCaption(Caption(id: id, speaker: speaker, text: text, isInterim: isInterim))
    }

    private func upsertCaption(_ caption: Caption) {
        if let index = captions.firstIndex(where: { $0.id == caption.id }) {
            captions[index] = caption
        } else {
            captions.append(caption)
        }
        // The overlay shows recent context; older lines are no longer useful on a phone.
        if captions.count > 8 {
            captions.removeFirst(captions.count - 8)
        }
    }

    private func rebuildTiles() {
        guard let room = conference else {
            deliverParticipantChanges([])
            tiles = []
            audioLevels = [:]
            appliedReceivePolicy = nil
            return
        }
        var rows: [Tile] = []

        // A muted camera keeps its track id (mute only disables transmission), so handing the
        // tile that id would freeze it on the last frame. nil renders the avatar instead.
        // A live screen share takes the local tile over the camera.
        let localVideo = room.localTracks.values
            .first { $0.mediaType == .video && $0.snapshot.videoType == .desktop && !$0.muted }?
            .id
            ?? room.localTracks.values
                .first { $0.mediaType == .video && !$0.muted }?
                .id
        rows.append(Tile(
            id: Tile.localID,
            displayName: room.options.userInfo.displayName,
            videoTrackID: localVideo,
            isLocal: true,
            isDominantSpeaker: false,
            raisedHand: isHandRaised,
            audioMuted: isAudioMuted,
            videoMuted: isVideoMuted,
            audioLevel: audioLevels[Tile.localID] ?? 0,
            connectionQuality: qualitySummary(for: Tile.localID) ?? quality,
            connectionQualityLevel: connectionQualityLevels[Tile.localID],
            role: room.isModerator ? .moderator : .participant,
            isModerator: room.isModerator,
            avatarURL: room.options.userInfo.avatarURL,
            email: room.options.userInfo.email
        ))

        for participant in room.participants.values.sorted(by: { $0.id < $1.id }) {
            let owned = participant.snapshot.tracks.filter { $0.mediaType == .video }
            let video = owned.first { !$0.muted }?.id
                ?? room.remoteTracks.values.first {
                    $0.owner == participant.id && $0.mediaType == .video && !$0.muted
                }?.id
            // `JitsiConference` derives this from the participant's tracks (all muted, or
            // none known yet) and keeps it current on track add/remove/mute.
            let audioMuted = participant.isAudioMuted
            rows.append(Tile(
                id: participant.id,
                displayName: participant.displayName.isEmpty ? "Guest" : participant.displayName,
                videoTrackID: video,
                isLocal: false,
                isDominantSpeaker: room.dominantSpeaker == participant.id,
                raisedHand: participant.raisedHand,
                audioMuted: audioMuted,
                videoMuted: participant.isVideoMuted || video == nil,
                audioLevel: audioLevels[participant.id] ?? 0,
                connectionQuality: qualitySummary(for: participant.id),
                connectionQualityLevel: connectionQualityLevels[participant.id],
                role: participant.role,
                isModerator: participant.isModerator,
                avatarURL: participant.avatarURL,
                email: participant.email
            ))
        }

        // A track can arrive before presence does. Only synthesize a tile for owners with no
        // participant row (and only one per owner): reusing a tile id makes `ForEach` drop
        // one of the cells.
        for track in room.remoteTracks.values
            where track.mediaType == .video
                && room.participants[track.owner] == nil
                && !rows.contains(where: { $0.id == track.owner }) {
            rows.append(Tile(
                id: track.owner,
                displayName: "Guest",
                videoTrackID: track.muted ? nil : track.id,
                isLocal: false,
                isDominantSpeaker: false,
                raisedHand: false,
                audioMuted: false,
                videoMuted: track.muted,
                audioLevel: audioLevels[track.owner] ?? 0,
                connectionQuality: qualitySummary(for: track.owner),
                connectionQualityLevel: connectionQualityLevels[track.owner],
                role: .participant,
                isModerator: false,
                avatarURL: nil,
                email: nil
            ))
        }

        let liveIds = Set(rows.map(\.id))
        if audioLevels.contains(where: { !liveIds.contains($0.key) }) {
            audioLevels = audioLevels.filter { liveIds.contains($0.key) }
        }
        tiles = rows
        deliverParticipantChanges(rows)
        updateReceivePolicy(gridSize: rows.count)
    }

    /// Normalizes the lib's per-track level into the tile's id space and republishes it.
    /// The local track reports `myUserId()`, while its tile is always `Tile.localID`.
    private func applyAudioLevels(_ latest: [ParticipantID: Double]) {
        let localID = conference?.localParticipantID
        var next = audioLevels
        for (id, raw) in latest {
            let key = id == localID ? Tile.localID : id
            let level = raw > 1 ? raw / 100 : Swift.min(Swift.max(raw, 0), 1)
            next[key] = level
            onAudioLevel?(key, level)
        }
        audioLevels = next
        rebuildTiles()
    }

    /// Diffs the new rows against the last delivered ones. A row whose only change is an
    /// audio level below/above the speaking threshold is silent, which keeps the callbacks
    /// useful as render triggers instead of a 5 Hz notification firehose.
    private func deliverParticipantChanges(_ rows: [Tile]) {
        let next = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        for row in rows where previousTiles[row.id] == nil {
            onParticipantJoined?(row)
            if !row.isLocal {
                onRemoteCanvasJoined?(ParticipantCanvas(session: self, participantID: row.id, style: canvasStyle))
            }
        }
        for (id, old) in previousTiles where next[id] == nil {
            onParticipantLeft?(old)
            if !old.isLocal {
                onRemoteCanvasLeft?(id)
            }
        }
        for row in rows {
            guard let old = previousTiles[row.id] else { continue }
            var change: ParticipantChange = []
            if old.audioMuted != row.audioMuted {
                change.insert(row.audioMuted ? .microphoneMuted : .microphoneUnmuted)
                noteRemoteMediaChange(row, mediaType: .audio)
            }
            if old.videoMuted != row.videoMuted {
                change.insert(row.videoMuted ? .cameraMuted : .cameraUnmuted)
                noteRemoteMediaChange(row, mediaType: .video)
            }
            if old.isSpeaking != row.isSpeaking {
                change.insert(row.isSpeaking ? .speakingStarted : .speakingStopped)
            }
            if old.isDominantSpeaker != row.isDominantSpeaker {
                change.insert(.dominantSpeakerChanged)
            }
            if old.raisedHand != row.raisedHand {
                change.insert(.raisedHandChanged)
            }
            if old.videoTrackID != row.videoTrackID {
                change.insert(.videoTrackChanged)
            }
            if old.displayName != row.displayName || old.avatarURL != row.avatarURL
                || old.email != row.email || old.role != row.role
                || old.isModerator != row.isModerator {
                change.insert(.profileChanged)
            }
            if !change.isEmpty {
                onParticipantChanged?(row, change)
            }
        }
        previousTiles = next
    }

    /// Forwards a remote microphone/camera toggle and feeds the coalescing window the
    /// `onHostMuteAll` heuristic uses.
    private func noteRemoteMediaChange(_ row: Tile, mediaType: MediaType) {
        guard !row.isLocal else { return }
        let isMuted = mediaType == .audio ? row.audioMuted : row.videoMuted
        onRemoteMediaChanged?(RemoteMediaChange(
            participantID: row.id,
            displayName: row.displayName,
            mediaType: mediaType,
            isMuted: isMuted
        ))
        guard isMuted else { return }
        muteBatchWindow[mediaType, default: []].insert(row.id)
        guard muteBatchTasks[mediaType] == nil else { return }
        muteBatchTasks[mediaType] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.muteBatchWindowNanos)
            guard !Task.isCancelled else { return }
            self?.flushMuteBatch(mediaType)
        }
    }

    private func flushMuteBatch(_ mediaType: MediaType) {
        muteBatchTasks[mediaType] = nil
        let ids = muteBatchWindow[mediaType] ?? []
        muteBatchWindow[mediaType] = nil
        guard ids.count >= Self.muteBatchMinimumParticipants, let handler = onHostMuteAll else { return }
        handler(HostMuteAll(mediaType: mediaType, participantIDs: ids.sorted()))
    }

    /// "good"/"fair"/"poor" from the lib's 0...100 figure, using the reference client's
    /// thresholds. Nil until the first stats sample for that participant.
    private func qualitySummary(for id: ParticipantID) -> String? {
        guard let level = connectionQualityLevels[id] else { return nil }
        if level >= 30 { return "good" }
        if level >= 10 { return "fair" }
        return "poor"
    }

    /// Builds the current snapshot from whatever sources have arrived. The server's room
    /// creation timestamp wins; the limit message's own clock is next; the local join time
    /// is the last resort so a timer still shows on deployments without either module.
    private func recomputeMeetingTiming() {
        guard let joinedAt = localJoinedAt else { return }
        let start: Date
        let source: MeetingTiming.StartSource
        if let serverCreatedAt {
            start = serverCreatedAt
            source = .serverCreated
        } else if let restrictedLimit {
            start = restrictedLimit.startedAt
            source = .serverRestricted
        } else {
            start = joinedAt
            source = .localJoin
        }

        let limit: (value: TimeInterval, source: MeetingTiming.LimitSource, start: Date)?
        if let restrictedLimit {
            limit = (restrictedLimit.duration, .serverEnforced, restrictedLimit.startedAt)
        } else if let hostLimit = request?.meetingTimeLimit, hostLimit > 0 {
            limit = (hostLimit, .hostConfigured, start)
        } else {
            limit = nil
        }

        meetingTiming = MeetingTiming(
            startedAt: start,
            startSource: source,
            timeLimit: limit?.value,
            limitSource: limit?.source,
            limitStartedAt: limit?.start,
            capturedAt: Date()
        )
    }

    private var hasCompleteTimingSources: Bool {
        serverCreatedAt != nil && (restrictedLimit != nil || (request?.meetingTimeLimit ?? 0) > 0)
    }

    /// Fires `onMeetingTiming` once. Complete sources deliver at once; otherwise the join
    /// handshake gets two seconds before the snapshot is taken as-is.
    private func scheduleMeetingTimingDelivery() {
        guard !hasDeliveredMeetingTiming else { return }
        if hasCompleteTimingSources {
            deliverMeetingTiming()
            return
        }
        guard timingDeliveryTask == nil else { return }
        timingDeliveryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.timingDeliveryTask = nil
            self?.deliverMeetingTiming()
        }
    }

    private func deliverMeetingTiming() {
        guard !hasDeliveredMeetingTiming, hasJoined else { return }
        timingDeliveryTask?.cancel()
        timingDeliveryTask = nil
        recomputeMeetingTiming()
        guard let timing = meetingTiming else { return }
        hasDeliveredMeetingTiming = true
        onMeetingTiming?(timing)
    }

    private struct TimeRestrictedLimit {
        let duration: TimeInterval
        let elapsed: TimeInterval
    }

    /// `mod_time_restricted` payload sent as the room: `{type, durationSeconds, elapsedSeconds}`.
    private static func parseTimeRestricted(_ text: String) -> TimeRestrictedLimit? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "time_restricted",
              let duration = (object["durationSeconds"] as? NSNumber)?.doubleValue,
              duration > 0
        else { return nil }
        let elapsed = (object["elapsedSeconds"] as? NSNumber)?.doubleValue ?? 0
        return TimeRestrictedLimit(duration: duration, elapsed: max(0, elapsed))
    }

    private func resetMeetingTiming() {
        timingDeliveryTask?.cancel()
        timingDeliveryTask = nil
        hasDeliveredMeetingTiming = false
        serverCreatedAt = nil
        restrictedLimit = nil
        localJoinedAt = nil
        meetingTiming = nil
    }

    /// Resolves a moderation actor's display name, covering this endpoint.
    private func actorName(for id: ParticipantID) -> String? {
        if id == conference?.localParticipantID {
            return request?.conference.userInfo.displayName
        }
        return conference?.participants[id]?.displayName
    }

    /// Scales the receive side with the grid, mirroring what the jitsi-meet client does:
    /// one or two tiles decode at 720p, a four-up grid at 360p, and larger grids at 180p
    /// with at most six forwarded videos. Each step down cuts decoder CPU and bandwidth.
    private func updateReceivePolicy(gridSize: Int) {
        let maxHeight: Int
        let lastN: Int
        if gridSize <= 2 {
            maxHeight = 720
            lastN = 1
        } else if gridSize <= 4 {
            maxHeight = 360
            lastN = gridSize - 1
        } else {
            maxHeight = 180
            lastN = 6
        }
        guard appliedReceivePolicy?.maxHeight != maxHeight || appliedReceivePolicy?.lastN != lastN else {
            return
        }
        appliedReceivePolicy = (maxHeight, lastN)
        Task { [conference] in
            try? await conference?.applyReceivePolicy(maxHeight: maxHeight, lastN: lastN)
        }
    }

    // MARK: - Local media state

    private func setPhase(_ next: MeetingPhase) {
        guard phase != next else { return }
        phase = next
        isJoined = next.isJoined
        onEvent?(.phaseChanged(next))
    }

    private func setLocalMedia(_ next: LocalMediaState) {
        guard localMedia != next else { return }
        localMedia = next
        onEvent?(.localMediaChanged(next))
    }

    private func mutateLocalMedia(_ change: (inout LocalMediaState) -> Void) {
        var next = localMedia
        change(&next)
        setLocalMedia(next)
    }

    /// Rebuilds the control-bar view of the live tracks. Fields with no live track keep their
    /// previous value so a capture-less session does not advertise a muted camera.
    private func syncLocalMedia(from room: JitsiConference?) {
        guard let room else { return }
        let tracks = room.localTracks.values
        let camera = tracks.first { $0.mediaType == .video && $0.snapshot.videoType != .desktop }
        let desktop = tracks.first { $0.mediaType == .video && $0.snapshot.videoType == .desktop }
        let microphone = tracks.first { $0.mediaType == .audio }
        var next = localMedia
        if let microphone {
            next.microphoneMuted = microphone.muted
            next.audioDeviceID = microphone.snapshot.deviceID ?? next.audioDeviceID
        }
        if let camera {
            next.cameraMuted = camera.muted
            if let deviceID = camera.snapshot.deviceID {
                next.cameraDeviceID = deviceID
                if let facing = discovery.enumerate().first(where: { $0.id == deviceID })?.facing,
                   facing != .unspecified {
                    next.isFrontCamera = facing == .user
                }
            }
        }
        next.screenSharing = desktop != nil
        setLocalMedia(next)
    }

}