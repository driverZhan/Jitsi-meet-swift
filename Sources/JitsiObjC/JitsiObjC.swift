import Foundation
import JitsiCore
import JitsiMeetSDK

/// Objective-C entry point.
///
/// This type is `@objc`, so the packaged framework ships a generated
/// `JitsiMeetSDK-Swift.h` and a Swift modulemap; an ObjC app uses it through
/// `@import JitsiMeetSDK;` and never has to write a single line of Swift. Every method that
/// performs I/O takes a completion block and reports through it on the main queue.
///
/// The façade deliberately exposes dictionaries/strings instead of the Swift model types so
/// the generated header stays free of Swift-only generics and enums.
@MainActor
@objcMembers
public final class JitsiSDK: NSObject {
    public static let shared = JitsiSDK()

    /// All callbacks happen on the main queue.
    public weak var delegate: JitsiSDKDelegate?

    public private(set) var isConnected = false
    public private(set) var isJoined = false
    /// ICE is retrying after the media path dropped; the room is still joined.
    public private(set) var isMediaInterrupted = false
    public private(set) var isAudioMuted = false
    public private(set) var isVideoMuted = false
    public private(set) var isScreenSharing = false
    public private(set) var lastError: String?

    /// True when `retryConnection()` can start a fresh rejoin: a join was attempted, the
    /// room is not up, and no automatic attempt is already running.
    public var canRetryConnection: Bool {
        lastJoin != nil && connectionOptions != nil && !isJoined && rejoinTask == nil
    }

    /// STUN/TURN URLs used for two-party (peer-to-peer) calls. Empty by default: the SDK
    /// never falls back to lib-jitsi-meet's public jitsi.net STUN server, which is
    /// unreachable from mainland China and discloses the device address.
    public var p2pSTUNServers: [String] = []

    /// Supplies a fresh JWT after the server reports the current one expired. Called on the
    /// main queue; pass nil from the block when no replacement is available.
    public var tokenProvider: ((@escaping (String?) -> Void) -> Void)?

    private var conference: JitsiConference?
    private var subscription: Subscription?
    /// Everything the last join used, so a dropped connection can be rebuilt without
    /// asking the app again.
    private var connectionOptions: ConnectionOptions?
    private var lastJoin: (options: ConferenceOptions, audio: Bool, video: Bool)?
    private var rejoinTask: Task<Void, Never>?
    private var rejoinAttempt = 0
    private var isNetworkOnline = true
    /// Set once the room has been joined; a lifecycle retry must not restart the initial
    /// join or a lobby wait, where `isJoined` is also false.
    private var hasJoined = false
    /// Set when the scene leaves the foreground, so only a real background round-trip
    /// grants a fresh rejoin quota.
    private var wasBackgrounded = false
    /// Drops each followed by a successful rejoin, cleared after `stableWindow` of stable
    /// connection. See the SwiftUI facade for why a success cannot reset the backoff.
    private var instability = 0
    private var stabilityTask: Task<Void, Never>?
    /// Consecutive failed attempts, not drops: a flapping link that rejoins each time must
    /// not exhaust the quota and strand the user.
    private static let maxRejoinAttempts = 3
    private static let stableWindow: TimeInterval = 30
    private static let maxInstability = 4

    private override init() {
        super.init()
    }

    // MARK: - Lifecycle

    /// Installs the JS engine. Call once, before `connect`.
    public func bootstrap(
        conferenceHost: String,
        logLevel: String = "info",
        debugSignaling: Bool = false,
        region: String = "international",
        completion: @escaping (NSError?) -> Void
    ) {
        observe()
        Task {
            do {
                _ = try await JitsiMeetSDK.bootstrap(
                    config: SDKConfig(
                        region: region == "chinaMainland" ? .chinaMainland : .international,
                        logLevel: logLevel,
                        debugSignaling: debugSignaling
                    ),
                    conferenceHost: conferenceHost
                )
                completion(nil)
            } catch {
                completion(Self.nsError(error))
            }
        }
    }

    public func shutdown() {
        resetRejoinState()
        subscription?.unsubscribe()
        subscription = nil
        conference = nil
        connectionOptions = nil
        lastJoin = nil
        isConnected = false
        isJoined = false
        isScreenSharing = false
        isMediaInterrupted = false
        Task { await JitsiMeetSDK.shutdown() }
    }

    // MARK: - Connection

    public func connect(
        serviceURL: String,
        domain: String,
        muc: String,
        token: String? = nil,
        username: String? = nil,
        password: String? = nil,
        completion: @escaping (NSError?) -> Void
    ) {
        resetRejoinState()
        let credentials: ConnectionOptions.Credentials? = {
            guard let username else { return nil }
            return ConnectionOptions.Credentials(username: username, password: password ?? "")
        }()
        let options = ConnectionOptions(
            serviceUrl: serviceURL,
            hosts: ConnectionOptions.Hosts(domain: domain, muc: muc),
            token: token,
            credentials: credentials,
            p2p: ConnectionOptions.P2PConfiguration(stunServers: p2pSTUNServers)
        )
        Task {
            guard let engine = JitsiMeet.shared.engine else {
                completion(Self.nsError(JitsiError.engineNotInstalled))
                return
            }
            do {
                try await engine.connect(options)
                connectionOptions = options
                isConnected = true
                publishState()
                completion(nil)
            } catch {
                completion(Self.nsError(error))
            }
        }
    }

    public func disconnect() {
        resetRejoinState()
        connectionOptions = nil
        lastJoin = nil
        Task {
            await JitsiMeet.shared.engine?.disconnect()
            isConnected = false
            isJoined = false
            isMediaInterrupted = false
            publishState()
        }
    }

    /// Supplies a fresh JWT after the server reports the current one expired.
    public func refreshToken(_ token: String, completion: @escaping (NSError?) -> Void) {
        Task {
            guard let engine = JitsiMeet.shared.engine else {
                completion(Self.nsError(JitsiError.engineNotInstalled))
                return
            }
            do {
                try await engine.refreshToken(token)
                completion(nil)
            } catch {
                completion(Self.nsError(error))
            }
        }
    }

    /// Host lifecycle hook: pass `true` when the scene becomes active, `false` otherwise.
    /// Returning from the background with the room already gone grants a fresh rejoin
    /// quota; a healthy call and a session that never joined are left untouched.
    public func setAppActive(_ active: Bool) {
        guard lastJoin != nil, connectionOptions != nil else {
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
        guard rejoinTask == nil else { return }
        retryConnection()
    }

    /// Manual recovery for the failures the automatic path deliberately does not retry:
    /// server 5xx, BOSH 499/400 and a Prosody-initiated disconnect. Reuses the rejoin loop,
    /// so the jittered backoff and the fresh-token path still apply.
    public func retryConnection() {
        guard lastJoin != nil, connectionOptions != nil, !isJoined, rejoinTask == nil else { return }
        rejoinAttempt = 0
        lastError = "Reconnecting…"
        publishState()
        scheduleRejoin()
    }

    // MARK: - Conference

    /// `email` and `avatarURL` are published with the join presence. They are nullable:
    /// ObjC has no default arguments, so askers pass nil for "not set".
    public func joinRoom(
        _ roomName: String,
        displayName: String,
        email: String? = nil,
        avatarURL: String? = nil,
        password: String? = nil,
        audio: Bool = true,
        video: Bool = true,
        completion: @escaping (NSError?) -> Void
    ) {
        resetRejoinState()
        Task {
            guard let engine = JitsiMeet.shared.engine else {
                completion(Self.nsError(JitsiError.engineNotInstalled))
                return
            }
            let options = ConferenceOptions(
                name: roomName,
                userInfo: UserInfo(displayName: displayName, email: email, avatarURL: avatarURL),
                password: password
            )
            let room = JitsiConference(options: options)
            room.onStateChange = { [weak self] in
                Task { @MainActor in self?.publishState() }
            }
            conference = room
            lastJoin = (options, audio, video)
            isNetworkOnline = engine.isNetworkOnline
            do {
                // Tracks registered before the join end up in the session answer; adding
                // them after leaves the native senders empty.
                try await engine.prepareConference(options)
                if audio || video {
                    var types: [MediaType] = []
                    if audio { types.append(.audio) }
                    if video { types.append(.video) }
                    _ = try await room.capture(types)
                }
                try await engine.joinConference(options)
                isJoined = true
                publishState()
                completion(nil)
            } catch {
                completion(Self.nsError(error))
            }
        }
    }

    public func leave() {
        resetRejoinState()
        lastJoin = nil
        Task {
            await conference?.leave()
            await JitsiMeet.shared.engine?.disconnect()
            conference = nil
            connectionOptions = nil
            isJoined = false
            isConnected = false
            isScreenSharing = false
            isMediaInterrupted = false
            publishState()
        }
    }

    // MARK: - Media

    public func setAudioMuted(_ muted: Bool, completion: @escaping (NSError?) -> Void) {
        media(completion: completion) { room in
            try await room.setMuted(muted, mediaType: .audio)
            self.isAudioMuted = muted
        }
    }

    public func setVideoMuted(_ muted: Bool, completion: @escaping (NSError?) -> Void) {
        media(completion: completion) { room in
            try await room.setMuted(muted, mediaType: .video)
            self.isVideoMuted = muted
        }
    }

    public func switchCamera(completion: @escaping (NSError?) -> Void) {
        media(completion: completion) { room in
            try await room.switchCamera()
        }
    }

    public func startScreenShare(completion: @escaping (NSError?) -> Void) {
        media(completion: completion) { room in
            _ = try await room.startScreenShare()
            self.isScreenSharing = true
        }
    }

    public func stopScreenShare() {
        Task {
            await conference?.stopScreenShare()
            isScreenSharing = false
            publishState()
        }
    }

    // MARK: - Signaling

    public func sendChat(_ text: String, completion: @escaping (NSError?) -> Void) {
        signaling(completion: completion) { room in
            try await room.sendChatMessage(text)
        }
    }

    public func setDisplayName(_ name: String, completion: @escaping (NSError?) -> Void) {
        signaling(completion: completion) { room in
            try await room.setDisplayName(name)
        }
    }

    public func raiseHand(_ raised: Bool, completion: @escaping (NSError?) -> Void) {
        signaling(completion: completion) { room in
            try await room.raiseHand(raised)
        }
    }

    /// False when the deployment has no Prosody polls component.
    public func pollsSupported(completion: @escaping (Bool) -> Void) {
        let room = conference
        Task {
            completion(await room?.pollsSupported() ?? false)
        }
    }

    public func createPoll(
        question: String,
        answers: [String],
        completion: @escaping (NSError?) -> Void
    ) {
        signaling(completion: completion) { room in
            try await room.createPoll(question: question, answers: answers)
        }
    }

    /// `answers` is positional and must match the poll's answer list.
    public func answerPoll(
        _ pollID: String,
        answers: [Bool],
        completion: @escaping (NSError?) -> Void
    ) {
        signaling(completion: completion) { room in
            try await room.answerPoll(pollID, answers: answers)
        }
    }

    public func kickParticipant(_ participantID: String, completion: @escaping (NSError?) -> Void) {
        signaling(completion: completion) { room in
            try await room.kick(participantID)
        }
    }

    /// Moderator action. Remote unmute is not supported by Jitsi, so `mute` must be `true`.
    public func muteParticipant(
        _ participantID: String,
        audio: Bool,
        mute: Bool,
        completion: @escaping (NSError?) -> Void
    ) {
        guard mute else {
            completion(Self.nsError(JitsiError.unsupported("remote unmute is not supported by Jitsi")))
            return
        }
        signaling(completion: completion) { room in
            try await room.mute(participantID, mediaType: audio ? .audio : .video)
        }
    }

    /// Local receive switch; affects only this device.
    public func setRemoteAudioMuted(_ muted: Bool, completion: @escaping (NSError?) -> Void) {
        signaling(completion: completion) { room in
            try await room.setRemoteAudioMuted(muted)
        }
    }

    // MARK: - Lobby / recording / E2EE

    public func enableLobby(completion: @escaping (NSError?) -> Void) {
        signaling(completion: completion) { room in
            try await room.enableLobby()
        }
    }

    public func disableLobby(completion: @escaping (NSError?) -> Void) {
        signaling(completion: completion) { room in
            try await room.disableLobby()
        }
    }

    public func joinLobby(displayName: String, email: String = "", completion: @escaping (NSError?) -> Void) {
        signaling(completion: completion) { room in
            try await room.joinLobby(displayName: displayName, email: email)
        }
    }

    public func startRecording(completion: @escaping (NSError?) -> Void) {
        signaling(completion: completion) { room in
            try await room.startRecording(RecordingOptions(mode: .file))
        }
    }

    public func stopRecording(completion: @escaping (NSError?) -> Void) {
        signaling(completion: completion) { room in
            try await room.stopRecording()
        }
    }

    public func enableE2EE(key: String, password: String? = nil, completion: @escaping (NSError?) -> Void) {
        signaling(completion: completion) { room in
            try await room.enableE2EE(key: key, password: password)
        }
    }

    public func disableE2EE(completion: @escaping (NSError?) -> Void) {
        signaling(completion: completion) { room in
            try await room.disableE2EE()
        }
    }

    // MARK: - State snapshots

    /// Participant rows: `id`, `displayName`, `role`, `raisedHand`, `tracks`.
    public func participants() -> [[String: Any]] {
        conference?.participants.values.map(Self.participantDictionary) ?? []
    }

    /// Local track rows: `id`, `mediaType`, `videoType`, `deviceID`, `muted`, `label`.
    public func localTracks() -> [[String: Any]] {
        conference?.localTracks.values.map { Self.trackDictionary($0.snapshot) } ?? []
    }

    /// Remote track rows: the same keys plus `owner`.
    public func remoteTracks() -> [[String: Any]] {
        conference?.remoteTracks.values.map { track in
            var row = Self.trackDictionary(track.snapshot)
            row["owner"] = track.owner
            return row
        } ?? []
    }

    public func conferenceState() -> [String: Any] {
        guard let conference else { return [:] }
        return [
            "isModerator": conference.isModerator,
            "lobbySupported": conference.lobbySupported,
            "lobbyEnabled": conference.lobbyEnabled,
            "authRequired": conference.authRequired,
            "passwordRequired": conference.passwordRequired
        ]
    }

    // MARK: - Internals

    private func media(completion: @escaping (NSError?) -> Void, _ body: @escaping (JitsiConference) async throws -> Void) {
        Task {
            guard let conference else {
                completion(Self.nsError(JitsiError.notInConference))
                return
            }
            do {
                try await body(conference)
                publishState()
                completion(nil)
            } catch {
                completion(Self.nsError(error))
            }
        }
    }

    private func signaling(completion: @escaping (NSError?) -> Void, _ body: @escaping (JitsiConference) async throws -> Void) {
        media(completion: completion, body)
    }

    /// Cancels a pending rejoin and forgets how unstable the link has been. Used by every
    /// path that deliberately leaves the room or starts a new session.
    private func resetRejoinState() {
        rejoinTask?.cancel()
        rejoinTask = nil
        rejoinAttempt = 0
        instability = 0
        hasJoined = false
        wasBackgrounded = false
        stabilityTask?.cancel()
        stabilityTask = nil
    }

    /// Full rejoin, the same recovery a jitsi-meet browser performs on `CONNECTION_DROPPED`:
    /// the BOSH session is gone, so the connection, tracks and room are rebuilt from the
    /// options of the last successful join, then the user's mute choices are re-applied.
    private func scheduleRejoin() {
        guard let join = lastJoin, let connection = connectionOptions, rejoinTask == nil else { return }
        rejoinTask = Task { [weak self] in
            guard let self else { return }
            await self.performRejoin(join, connection)
            self.rejoinTask = nil
        }
    }

    private func performRejoin(
        _ join: (options: ConferenceOptions, audio: Bool, video: Bool),
        _ connection: ConnectionOptions
    ) async {
        while rejoinAttempt < Self.maxRejoinAttempts {
            // Retrying against a radio that is still down only burns the quota; wait for a
            // path, then reconnect immediately.
            var waitedForNetwork = false
            if !isNetworkOnline {
                lastError = "Waiting for network…"
                publishState()
                // Capped: `.satisfied` follows the internet route, which a restricted LAN
                // can fail while the signalling host is still reachable.
                let deadline = Date().addingTimeInterval(30)
                while !isNetworkOnline && !Task.isCancelled && Date() < deadline {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                }
                guard !Task.isCancelled else { return }
                waitedForNetwork = true
            }
            rejoinAttempt += 1
            if !waitedForNetwork {
                // Jittered backoff: 1.5s–3s for a lone drop, growing with each recent drop
                // so a flapping link is not hammered every couple of seconds.
                let base = 1.5 * Double(max(1, instability))
                let delay = base + Double.random(in: 0...base)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled, let engine = JitsiMeet.shared.engine else { return }
            lastError = instability >= 3
                ? "Network unstable, reconnecting… (\(rejoinAttempt)/\(Self.maxRejoinAttempts))"
                : "Reconnecting… (\(rejoinAttempt)/\(Self.maxRejoinAttempts))"
            publishState()

            let room = JitsiConference(options: join.options)
            room.onStateChange = { [weak self] in
                Task { @MainActor in self?.publishState() }
            }
            conference = room
            isMediaInterrupted = false
            let authenticated = await connectionWithFreshToken(connection)
            await engine.resetForRejoin()
            do {
                try await engine.connect(authenticated)
                try await engine.prepareConference(join.options)
                if join.audio || join.video {
                    var types: [MediaType] = []
                    if join.audio { types.append(.audio) }
                    if join.video { types.append(.video) }
                    _ = try await room.capture(types)
                    if isAudioMuted { try? await room.setMuted(true, mediaType: .audio) }
                    if isVideoMuted { try? await room.setMuted(true, mediaType: .video) }
                }
                // Only the joined event proves the room is up; `join()` alone returns while
                // the MUC join is still in flight and would report a false success.
                try await engine.joinConference(join.options, waitForJoin: 15)
                // A leave() during the join wait must win over restoring state into a room
                // the user already left.
                guard !Task.isCancelled else { return }
                isConnected = true
                isJoined = true
                rejoinAttempt = 0
                lastError = nil
                scheduleStabilityReset()
                if isScreenSharing {
                    // The lib disposed the desktop track with the connection; the broadcast
                    // extension reconnects to the app-group socket on its next frame.
                    do {
                        _ = try await room.startScreenShare()
                    } catch {
                        isScreenSharing = false
                        lastError = "Screen share stopped: \(error.localizedDescription)"
                    }
                }
                publishState()
                return
            } catch {
                isConnected = false
                isJoined = false
                lastError = "Reconnect attempt \(rejoinAttempt) failed: \(error.localizedDescription)"
                publishState()
            }
        }
        // Out of attempts: release the audio session instead of holding the microphone open
        // in front of a dead connection.
        await JitsiMeet.shared.engine?.disconnect()
        lastError = "Connection lost. Leave and rejoin to continue."
        publishState()
    }

    /// Clears the escalated backoff only after the link stayed up long enough. Cancelled by
    /// the next drop, so a flapping Wi-Fi keeps its accumulated delay.
    private func scheduleStabilityReset() {
        stabilityTask?.cancel()
        stabilityTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.stableWindow * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.instability = 0
            self.stabilityTask = nil
        }
    }

    /// Calls the host's token provider and waits for the replacement JWT. Without it a
    /// reconnect after the token's lifetime cannot authenticate, because the lib only asks
    /// for a new token while resuming a live stream.
    private func connectionWithFreshToken(_ connection: ConnectionOptions) async -> ConnectionOptions {
        guard connection.token != nil, let provider = tokenProvider else { return connection }
        let token = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            provider { continuation.resume(returning: $0) }
        }
        guard let token, !token.isEmpty else { return connection }
        var refreshed = connection
        refreshed.token = token
        return refreshed
    }

    private func observe() {
        subscription?.unsubscribe()
        subscription = JitsiMeet.shared.events.subscribe { [weak self] event in
            Task { @MainActor in
                self?.apply(event)
            }
        }
    }

    private func apply(_ event: MeetingEvent) {
        switch event {
        case .connectionStatus(let status, let detail):
            isConnected = status == .connected
            if status == .error {
                lastError = detail
            }
        case .conferenceJoined:
            isJoined = true
            hasJoined = true
        case .connectionInterrupted:
            isMediaInterrupted = true
            publishState()
        case .connectionRestored:
            isMediaInterrupted = false
            publishState()
        case .networkChanged(let online):
            isNetworkOnline = online
            publishState()
        case .conferenceLeft(let reason):
            isJoined = false
            lastError = reason
        case .conferenceFailed(let error):
            isJoined = false
            lastError = error.localizedDescription
        case .connectionLost(let reason):
            // The lib already disposed the local tracks and can no longer resume this
            // conference; rebuild the connection and rejoin the same room.
            isJoined = false
            isConnected = false
            lastError = reason
            // Backoff escalation survives a successful rejoin; only a link that stays up
            // clears it, otherwise a flapping radio is retried at the same 1.5 s forever.
            stabilityTask?.cancel()
            stabilityTask = nil
            instability = min(instability + 1, Self.maxInstability)
            publishState()
            scheduleRejoin()
        case .tokenExpired:
            lastError = "Session token expired"
            publishState()
            if let provider = tokenProvider {
                provider { [weak self] token in
                    guard let self, let token, !token.isEmpty else { return }
                    self.refreshToken(token) { _ in }
                }
            }
        case .localTrackAdded, .localTrackRemoved, .remoteTrackAdded, .remoteTrackRemoved,
             .trackMuteChanged, .participantJoined, .participantLeft,
             .participantDisplayNameChanged, .participantAvatarChanged, .participantEmailChanged,
             .participantRoleChanged, .raisedHandChanged, .dominantSpeakerChanged:
            publishState()
        case .chatMessage(let from, let text, let isPrivate):
            delegate?.jitsiDidReceiveEvent?("chatMessage", payload: [
                "from": from, "text": text, "isPrivate": isPrivate
            ])
        default:
            break
        }
        delegate?.jitsiDidReceiveEvent?(event.rawName, payload: event.rawPayload)
    }

    private func publishState() {
        delegate?.jitsiDidChangeState(stateSnapshot())
    }

    private func stateSnapshot() -> [String: Any] {
        var snapshot: [String: Any] = [
            "isConnected": isConnected,
            "isJoined": isJoined,
            "isMediaInterrupted": isMediaInterrupted,
            "isNetworkOnline": isNetworkOnline,
            "isAudioMuted": isAudioMuted,
            "isVideoMuted": isVideoMuted,
            "isScreenSharing": isScreenSharing,
            "participants": participants(),
            "localTracks": localTracks(),
            "remoteTracks": remoteTracks()
        ]
        if let lastError {
            snapshot["lastError"] = lastError
        }
        return snapshot
    }

    private static func participantDictionary(_ participant: JitsiParticipant) -> [String: Any] {
        var row: [String: Any] = [
            "id": participant.id,
            "displayName": participant.displayName,
            "role": participant.role.rawValue,
            "raisedHand": participant.raisedHand,
            "tracks": participant.snapshot.tracks.map(trackDictionary)
        ]
        if let avatarURL = participant.avatarURL {
            row["avatarURL"] = avatarURL
        }
        if let email = participant.email {
            row["email"] = email
        }
        return row
    }

    private static func trackDictionary(_ track: TrackSnapshot) -> [String: Any] {
        var row: [String: Any] = [
            "id": track.id,
            "mediaType": track.mediaType.rawValue,
            "videoType": track.videoType.rawValue,
            "muted": track.muted,
            "isLocal": track.isLocal,
            "label": track.label
        ]
        if let deviceID = track.deviceID {
            row["deviceID"] = deviceID
        }
        return row
    }

    private static func nsError(_ error: Error) -> NSError {
        error as NSError
    }
}

/// Callbacks are delivered on the main queue.
@objc(JitsiSDKDelegate)
public protocol JitsiSDKDelegate: AnyObject {
    /// Called after every connection, participant, track or mute change.
    func jitsiDidChangeState(_ state: [String: Any])

    /// Raw meeting events that have no dedicated state change (chat, endpoint messages,
    /// recording, E2EE and so on).
    @objc optional func jitsiDidReceiveEvent(_ name: String, payload: [String: Any])
}

private extension MeetingEvent {
    /// A stable name for the ObjC event channel; typed events already drove state changes.
    var rawName: String {
        if case .raw(let name, _) = self { return name }
        switch self {
        case .connectionStatus: return "connectionStatus"
        case .connectionInterrupted: return "connectionInterrupted"
        case .connectionRestored: return "connectionRestored"
        case .networkChanged: return "networkChanged"
        case .connectionLost: return "connectionLost"
        case .tokenExpired: return "tokenExpired"
        case .conferenceJoined: return "conferenceJoined"
        case .conferenceLeft: return "conferenceLeft"
        case .conferenceFailed: return "conferenceFailed"
        case .participantJoined: return "participantJoined"
        case .participantLeft: return "participantLeft"
        case .participantDisplayNameChanged: return "participantDisplayNameChanged"
        case .participantAvatarChanged: return "participantAvatarChanged"
        case .participantEmailChanged: return "participantEmailChanged"
        case .participantRoleChanged: return "participantRoleChanged"
        case .participantMuted: return "participantMuted"
        case .raisedHandChanged: return "raisedHandChanged"
        case .dominantSpeakerChanged: return "dominantSpeakerChanged"
        case .localTrackAdded: return "localTrackAdded"
        case .localTrackRemoved: return "localTrackRemoved"
        case .remoteTrackAdded: return "remoteTrackAdded"
        case .remoteTrackRemoved: return "remoteTrackRemoved"
        case .trackMuteChanged: return "trackMuteChanged"
        case .audioLevels: return "audioLevels"
        case .connectionQualityLevel: return "connectionQuality"
        case .chatMessage: return "chatMessage"
        case .endpointMessage: return "endpointMessage"
        case .recordingStateChanged: return "recordingStateChanged"
        case .e2EEStateChanged: return "e2eeStateChanged"
        case .kick: return "participantKicked"
        case .raw(let name, _): return name
        }
    }

    var rawPayload: [String: Any] {
        func convert(_ value: JSONValue) -> Any {
            switch value {
            case .null: return NSNull()
            case .bool(let flag): return flag
            case .number(let number): return number
            case .string(let text): return text
            case .array(let values): return values.map(convert)
            case .object(let entries): return entries.mapValues(convert)
            }
        }
        if case .raw(_, let payload) = self {
            return convert(payload) as? [String: Any] ?? [:]
        }
        switch self {
        case .connectionLost(let reason):
            return ["reason": reason ?? ""]
        case .tokenExpired(let resumable):
            return ["resumable": resumable]
        case .networkChanged(let online):
            return ["online": online]
        default:
            return [:]
        }
    }
}
