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
    private static let maxRejoinAttempts = 3

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
        rejoinTask?.cancel()
        rejoinTask = nil
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
        rejoinTask?.cancel()
        rejoinTask = nil
        rejoinAttempt = 0
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
        rejoinTask?.cancel()
        rejoinTask = nil
        rejoinAttempt = 0
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
        rejoinTask?.cancel()
        rejoinTask = nil
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
            rejoinAttempt = 0
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
        rejoinTask?.cancel()
        rejoinTask = nil
        rejoinAttempt = 0
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
            rejoinAttempt += 1
            // Jittered backoff: 1.5s–3s for the first try, growing with each attempt.
            let base = 1.5 * Double(rejoinAttempt)
            let delay = base + Double.random(in: 0...base)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let engine = JitsiMeet.shared.engine else { return }

            let room = JitsiConference(options: join.options)
            room.onStateChange = { [weak self] in
                Task { @MainActor in self?.publishState() }
            }
            conference = room
            isMediaInterrupted = false
            await engine.disconnect()
            do {
                try await engine.connect(connection)
                try await engine.prepareConference(join.options)
                if join.audio || join.video {
                    var types: [MediaType] = []
                    if join.audio { types.append(.audio) }
                    if join.video { types.append(.video) }
                    _ = try await room.capture(types)
                    if isAudioMuted { try? await room.setMuted(true, mediaType: .audio) }
                    if isVideoMuted { try? await room.setMuted(true, mediaType: .video) }
                }
                try await engine.joinConference(join.options)
                isConnected = true
                isJoined = true
                rejoinAttempt = 0
                lastError = nil
                publishState()
                return
            } catch {
                isConnected = false
                isJoined = false
                lastError = "Reconnect attempt \(rejoinAttempt) failed: \(error.localizedDescription)"
                publishState()
            }
        }
        lastError = "Connection lost. Leave and rejoin to continue."
        publishState()
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
        case .connectionInterrupted:
            isMediaInterrupted = true
            publishState()
        case .connectionRestored:
            isMediaInterrupted = false
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
        default:
            return [:]
        }
    }
}
