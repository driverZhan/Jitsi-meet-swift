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
    /// True while a breakout switch runs; the room is leaving one MUC and joining the other.
    public private(set) var isSwitchingRoom = false
    /// ICE is retrying after the media path dropped; the room is still joined.
    public private(set) var isMediaInterrupted = false
    public private(set) var isAudioMuted = false
    public private(set) var isVideoMuted = false
    public private(set) var isScreenSharing = false
    public private(set) var isLocked = false
    /// True while this endpoint knocked in a members-only room's lobby and waits for a
    /// moderator to admit it.
    public private(set) var isWaitingInLobby = false
    /// True when the members-only refusal carried `<waiting-for-host/>`. Such a lobby has no
    /// approval step: an authenticated host starting the meeting admits everyone in it.
    public private(set) var isWaitingForHost = false
    /// True when the join was refused with `conference.passwordRequired`. Join again with the
    /// password in `ConferenceOptions`; only the user knows it, so nothing is retried here.
    public private(set) var requiresPassword = false
    /// Deployment info from the XMPP server (`PROPERTIES_UPDATED`).
    public private(set) var serverRegion: String?
    public private(set) var serverShard: String?
    public private(set) var lastError: String?

    /// True when `retryConnection()` can start a fresh rejoin: a join was attempted, the
    /// room is not up, and no automatic attempt, lobby wait or password prompt is running.
    public var canRetryConnection: Bool {
        lastJoin != nil && connectionOptions != nil && !isJoined
            && !isWaitingInLobby && !requiresPassword && rejoinTask == nil
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
    /// The room passed to `joinRoom`. `lastJoin.options` follows breakout switches; this
    /// does not, so "leave breakout" and a failed recovery still have the main room.
    private var mainJoin: ConferenceOptions?
    private var switchTask: Task<Void, Never>?
    private var rejoinTask: Task<Void, Never>?
    private var lobbyKnockTask: Task<Void, Never>?
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
    private static let membersOnlyError = "conference.connectionError.membersOnly"
    private static let accessDeniedError = "conference.connectionError.accessDenied"
    private static let passwordRequiredError = "conference.passwordRequired"
    private static let waitingForModeratorMessage = "Waiting for a moderator to let you in…"
    private static let waitingForHostMessage = "Waiting for the host to start the meeting…"
    private static let passwordRequiredMessage = "This room requires a password."

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
        switchTask?.cancel()
        switchTask = nil
        isSwitchingRoom = false
        connectionOptions = nil
        lastJoin = nil
        mainJoin = nil
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

    /// Full JID of the established XMPP session, or nil before it exists.
    public func connectionJID(completion: @escaping (String?, NSError?) -> Void) {
        Task {
            guard let engine = JitsiMeet.shared.engine else {
                completion(nil, Self.nsError(JitsiError.engineNotInstalled))
                return
            }
            do {
                completion(try await engine.connectionJID(), nil)
            } catch {
                completion(nil, Self.nsError(error))
            }
        }
    }

    /// Transport timing marks collected while connecting.
    public func connectionTimes(completion: @escaping ([String: Any]?, NSError?) -> Void) {
        Task {
            guard let engine = JitsiMeet.shared.engine else {
                completion(nil, Self.nsError(JitsiError.engineNotInstalled))
                return
            }
            do {
                let value = Self.anyValue(try await engine.connectionTimes())
                completion(value as? [String: Any] ?? [:], nil)
            } catch {
                completion(nil, Self.nsError(error))
            }
        }
    }

    /// Publishes an XEP-0115 caps feature; `submit` republishes presence immediately.
    public func addConnectionFeature(
        _ feature: String,
        submit: Bool,
        completion: @escaping (NSError?) -> Void
    ) {
        Task {
            guard let engine = JitsiMeet.shared.engine else {
                completion(Self.nsError(JitsiError.engineNotInstalled))
                return
            }
            do {
                guard !feature.isEmpty else { throw JitsiError.invalidArgument("feature is required") }
                try await engine.addConnectionFeature(feature, submit: submit)
                completion(nil)
            } catch {
                completion(Self.nsError(error))
            }
        }
    }

    public func removeConnectionFeature(
        _ feature: String,
        submit: Bool,
        completion: @escaping (NSError?) -> Void
    ) {
        Task {
            guard let engine = JitsiMeet.shared.engine else {
                completion(Self.nsError(JitsiError.engineNotInstalled))
                return
            }
            do {
                guard !feature.isEmpty else { throw JitsiError.invalidArgument("feature is required") }
                try await engine.removeConnectionFeature(feature, submit: submit)
                completion(nil)
            } catch {
                completion(Self.nsError(error))
            }
        }
    }

    /// Resumes an XMPP session created elsewhere (rid + sid + jid).
    public func attach(
        rid: String,
        sid: String,
        jid: String,
        completion: @escaping (NSError?) -> Void
    ) {
        Task {
            guard let engine = JitsiMeet.shared.engine else {
                completion(Self.nsError(JitsiError.engineNotInstalled))
                return
            }
            do {
                guard !rid.isEmpty, !sid.isEmpty, !jid.isEmpty else {
                    throw JitsiError.invalidArgument("rid, sid and jid are required")
                }
                try await engine.attachConnection(rid: rid, sid: sid, jid: jid)
                completion(nil)
            } catch {
                completion(Self.nsError(error))
            }
        }
    }

    /// Jingle/XMPP transcripts for support bundles. Only available with `debugSignaling`
    /// enabled, because the payloads contain JWTs and TURN credentials.
    public func connectionLogs(completion: @escaping ([String: Any]?, NSError?) -> Void) {
        Task {
            guard let engine = JitsiMeet.shared.engine else {
                completion(nil, Self.nsError(JitsiError.engineNotInstalled))
                return
            }
            do {
                let value = Self.anyValue(try await engine.connectionLogs())
                completion(value as? [String: Any] ?? [:], nil)
            } catch {
                completion(nil, Self.nsError(error))
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
        guard lastJoin != nil, connectionOptions != nil, !isJoined,
              !isWaitingInLobby, !requiresPassword, rejoinTask == nil else { return }
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
            mainJoin = options
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
        switchTask?.cancel()
        switchTask = nil
        isSwitchingRoom = false
        lastJoin = nil
        mainJoin = nil
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

    /// Changes capture resolution/frame rate without recreating the track. Pass 0 for a
    /// dimension to keep it unchanged.
    public func applyVideoConstraints(
        width: Int,
        height: Int,
        frameRate: Int,
        completion: @escaping (NSError?) -> Void
    ) {
        media(completion: completion) { room in
            _ = try await room.applyVideoConstraints(VideoConstraints(
                width: width > 0 ? width : nil,
                height: height > 0 ? height : nil,
                frameRate: frameRate > 0 ? frameRate : nil
            ))
        }
    }

    /// Supported camera formats plus the active resolution/frame rate, as a dictionary:
    /// `formats` (array of width/height/minFrameRate/maxFrameRate), `activeWidth`,
    /// `activeHeight`, `activeFrameRate`, `deviceId`.
    public func videoCapabilities(completion: @escaping ([String: Any]?, NSError?) -> Void) {
        guard let conference else {
            completion(nil, Self.nsError(JitsiError.notInConference))
            return
        }
        Task {
            do {
                completion(Self.dictionary(for: try await conference.videoCapabilities()), nil)
            } catch {
                completion(nil, Self.nsError(error))
            }
        }
    }

    /// Dominant-speaker report rows: `participantId`, `displayName`, `isLocal`,
    /// `isDominantSpeaker`, `totalDominantSpeakerTime` (seconds), `hasLeft`, `faceLandmarks`.
    public func speakerStats(completion: @escaping ([[String: Any]]?, NSError?) -> Void) {
        guard let conference else {
            completion(nil, Self.nsError(JitsiError.notInConference))
            return
        }
        Task {
            do {
                completion(try await conference.speakerStats().map(Self.speakerStatsDictionary), nil)
            } catch {
                completion(nil, Self.nsError(error))
            }
        }
    }

    /// Logs in with the given credentials on a side connection and asks Jicofo to upgrade
    /// this conference's role. The main XMPP session is untouched.
    public func authenticateAndUpgradeRole(
        id: String,
        password: String,
        completion: @escaping (NSError?) -> Void
    ) {
        guard let conference else {
            completion(Self.nsError(JitsiError.notInConference))
            return
        }
        Task {
            do {
                try await conference.authenticateAndUpgradeRole(id: id, password: password)
                completion(nil)
            } catch {
                completion(Self.nsError(error))
            }
        }
    }

    /// DTMF tones over the active audio sender; duration and pause are milliseconds.
    public func sendTones(
        _ tones: String,
        duration: Int,
        pause: Int,
        completion: @escaping (NSError?) -> Void
    ) {
        guard let conference else {
            completion(Self.nsError(JitsiError.notInConference))
            return
        }
        Task {
            do {
                try await conference.sendTones(tones, duration: duration, pause: pause)
                completion(nil)
            } catch {
                completion(Self.nsError(error))
            }
        }
    }

    /// True when the deployment has a SIP gateway component.
    public func isSIPCallingSupported(completion: @escaping (Bool, NSError?) -> Void) {
        guard let conference else {
            completion(false, Self.nsError(JitsiError.notInConference))
            return
        }
        Task {
            do {
                completion(try await conference.isSIPCallingSupported(), nil)
            } catch {
                completion(false, Self.nsError(error))
            }
        }
    }

    /// Dials a phone number into the room through the SIP gateway.
    public func dial(_ number: String, completion: @escaping (NSError?) -> Void) {
        guard let conference else {
            completion(Self.nsError(JitsiError.notInConference))
            return
        }
        Task {
            do {
                try await conference.dial(number)
                completion(nil)
            } catch {
                completion(Self.nsError(error))
            }
        }
    }

    /// Swaps local tracks in a single renegotiation. Pass an empty string for either id:
    /// empty old adds the new track, empty new removes the old one.
    public func replaceLocalTrack(
        _ oldTrackID: String,
        with newTrackID: String,
        completion: @escaping (NSError?) -> Void
    ) {
        media(completion: completion) { room in
            _ = try await room.replaceTrack(
                oldTrackID.isEmpty ? nil : oldTrackID,
                with: newTrackID.isEmpty ? nil : newTrackID)
        }
    }

    /// Per-source bridge hints. Pass nil/0 to leave a field unchanged. Keys of
    /// `sourceMaxHeights` are remote track source names.
    public func setReceiverConstraints(
        lastN: NSNumber?,
        defaultMaxHeight: NSNumber?,
        assumedBandwidthBps: NSNumber?,
        sourceMaxHeights: [String: NSNumber],
        completion: @escaping (NSError?) -> Void
    ) {
        media(completion: completion) { room in
            try await room.setReceiverConstraints(ReceiverConstraints(
                lastN: lastN.map(\.intValue),
                defaultMaxHeight: defaultMaxHeight.map(\.intValue),
                sourceMaxHeights: sourceMaxHeights.mapValues(\.intValue),
                assumedBandwidthBps: assumedBandwidthBps.map(\.intValue)))
        }
    }

    public func setDesktopSharingFrameRate(
        _ maxFps: Int,
        completion: @escaping (Bool, NSError?) -> Void
    ) {
        guard let conference else {
            completion(false, Self.nsError(JitsiError.notInConference))
            return
        }
        Task {
            do {
                completion(try await conference.setDesktopSharingFrameRate(maxFps), nil)
            } catch {
                completion(false, Self.nsError(error))
            }
        }
    }

    /// `speaker` or `receiver`; external audio routes take precedence while connected.
    public func setAudioOutputRoute(
        _ route: String,
        completion: @escaping (NSError?) -> Void
    ) {
        guard let parsed = AudioOutputRoute(rawValue: route) else {
            completion(Self.nsError(JitsiError.invalidArgument("audio route must be speaker or receiver")))
            return
        }
        media(completion: completion) { room in
            try await room.setAudioOutputRoute(parsed)
        }
    }

    public func audioOutputRoute(completion: @escaping (String?, NSError?) -> Void) {
        guard let conference else {
            completion(nil, Self.nsError(JitsiError.notInConference))
            return
        }
        Task {
            do {
                completion(try await conference.audioOutputRoute().rawValue, nil)
            } catch {
                completion(nil, Self.nsError(error))
            }
        }
    }

    /// TURN relay probe. Each server dictionary supports `urls` (string or array),
    /// `username` and `credential`.
    public func runPreCallTest(
        iceServers: [[String: Any]],
        completion: @escaping ([String: Any]?, NSError?) -> Void
    ) {
        Task {
            do {
                let servers = iceServers.map { raw -> PreCallTestServer in
                    let urls: [String]
                    if let list = raw["urls"] as? [String] {
                        urls = list
                    } else if let single = raw["urls"] as? String {
                        urls = [single]
                    } else {
                        urls = []
                    }
                    return PreCallTestServer(
                        urls: urls,
                        username: raw["username"] as? String,
                        credential: raw["credential"] as? String)
                }
                let result = try await JitsiMeet.shared.runPreCallTest(servers)
                var row: [String: Any] = ["mediaConnectivity": result.mediaConnectivity]
                if let throughput = result.throughput { row["throughput"] = throughput }
                if let loss = result.fractionalLoss { row["fractionalLoss"] = loss }
                if let rtt = result.rtt { row["rtt"] = rtt }
                if let jitter = result.jitter { row["jitter"] = jitter }
                completion(row, nil)
            } catch {
                completion(nil, Self.nsError(error))
            }
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

    /// Sends a structured `json-message`; `payload` must be JSON-serializable and its top
    /// level must be an object. `participantID == nil` broadcasts to the room.
    public func sendJSONChat(
        _ payload: [String: Any],
        to participantID: String?,
        completion: @escaping (NSError?) -> Void
    ) {
        signaling(completion: completion) { room in
            let data = try JSONSerialization.data(withJSONObject: payload)
            try await room.sendJSONMessage(try JSONValue(from: data), to: participantID)
        }
    }

    /// Data-channel object message; peers receive it as the `endpointMessage` event.
    public func sendEndpointMessage(
        _ payload: [String: Any],
        to participantID: String?,
        completion: @escaping (NSError?) -> Void
    ) {
        signaling(completion: completion) { room in
            let data = try JSONSerialization.data(withJSONObject: payload)
            try await room.sendEndpointMessage(try JSONValue(from: data), to: participantID)
        }
    }

    /// Sends a presence command. `values` become attributes of the command's extension, the
    /// same mechanism raise-hand and identity use.
    public func sendCommand(
        _ name: String,
        values: [String: Any],
        completion: @escaping (NSError?) -> Void
    ) {
        signaling(completion: completion) { room in
            try await room.sendCommand(name, values: try Self.commandValues(values))
        }
    }

    public func sendCommandOnce(
        _ name: String,
        values: [String: Any],
        completion: @escaping (NSError?) -> Void
    ) {
        signaling(completion: completion) { room in
            try await room.sendCommandOnce(name, values: try Self.commandValues(values))
        }
    }

    public func removeCommand(_ name: String, completion: @escaping (NSError?) -> Void) {
        signaling(completion: completion) { room in
            try await room.removeCommand(name)
        }
    }

    /// Deliveries of this command arrive as the `commandReceived` event.
    public func addCommandListener(_ name: String, completion: @escaping (NSError?) -> Void) {
        signaling(completion: completion) { room in
            try await room.addCommandListener(name)
        }
    }

    public func removeCommandListener(_ name: String, completion: @escaping (NSError?) -> Void) {
        signaling(completion: completion) { room in
            try await room.removeCommandListener(name)
        }
    }

    /// XEP-0459 reaction. `messageID` attaches it to a chat message; pass nil for a
    /// standalone reaction. `participantID == nil` broadcasts.
    public func sendReaction(
        _ reaction: String,
        messageID: String?,
        to participantID: String?,
        completion: @escaping (NSError?) -> Void
    ) {
        signaling(completion: completion) { room in
            try await room.sendReaction(reaction, messageID: messageID ?? "", to: participantID)
        }
    }

    private static func commandValues(_ values: [String: Any]) throws -> [String: JSONValue] {
        let data = try JSONSerialization.data(withJSONObject: values)
        return try JSONValue(from: data).objectValue
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

    // MARK: - Conference control (moderator)

    /// Ends the room for everyone. Check `conferenceState()["canEndConference"]` first.
    public func endConference(completion: @escaping (NSError?) -> Void) {
        signaling(completion: completion) { room in
            try await room.end()
        }
    }

    /// Sets or replaces the room password. Only a moderator may call it.
    public func lockRoom(password: String = "", completion: @escaping (NSError?) -> Void) {
        signaling(completion: completion) { room in
            try await room.lock(password: password)
        }
    }

    public func unlockRoom(completion: @escaping (NSError?) -> Void) {
        signaling(completion: completion) { room in
            try await room.unlock()
        }
    }

    public func grantModerator(_ participantID: String, completion: @escaping (NSError?) -> Void) {
        signaling(completion: completion) { room in
            try await room.grantOwner(participantID)
        }
    }

    /// Passing the local participant id makes the moderator resign.
    public func revokeModerator(_ participantID: String, completion: @escaping (NSError?) -> Void) {
        signaling(completion: completion) { room in
            try await room.revokeOwner(participantID)
        }
    }

    /// Marks the local user as having joined without audio; peers skip the join chime.
    public func setSilent(_ silent: Bool, completion: @escaping (NSError?) -> Void) {
        signaling(completion: completion) { room in
            try await room.setSilent(silent)
        }
    }

    public func setSubject(_ subject: String, completion: @escaping (NSError?) -> Void) {
        signaling(completion: completion) { room in
            try await room.setSubject(subject)
        }
    }

    public func setStartMutedPolicy(
        audio: Bool,
        video: Bool,
        completion: @escaping (NSError?) -> Void
    ) {
        signaling(completion: completion) { room in
            try await room.setStartMutedPolicy(audio: audio, video: video)
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

    // MARK: - Participant properties, lobby moderation and AV moderation

    /// Publishes a presence property. The value must be a JSON string, number, boolean or
    /// array of strings; anything else is rejected by the JS boundary.
    public func setLocalParticipantProperty(
        _ name: String,
        value: Any,
        completion: @escaping (NSError?) -> Void
    ) {
        signaling(completion: completion) { room in
            try await room.setLocalParticipantProperty(name, value: try Self.jsonValue(value))
        }
    }

    public func removeLocalParticipantProperty(_ name: String, completion: @escaping (NSError?) -> Void) {
        signaling(completion: completion) { room in
            try await room.removeLocalParticipantProperty(name)
        }
    }

    public func localParticipantProperty(
        _ name: String,
        completion: @escaping (Any?, NSError?) -> Void
    ) {
        guard let room = conference else {
            completion(nil, Self.nsError(JitsiError.notInConference))
            return
        }
        Task {
            do {
                let value = try await room.localParticipantProperty(name)
                completion(value.map(Self.anyValue), nil)
            } catch {
                completion(nil, Self.nsError(error))
            }
        }
    }

    public func approveLobbyUser(_ participantID: String, completion: @escaping (NSError?) -> Void) {
        signaling(completion: completion) { room in
            try await room.approveLobbyUser(participantID)
        }
    }

    public func denyLobbyUser(_ participantID: String, completion: @escaping (NSError?) -> Void) {
        signaling(completion: completion) { room in
            try await room.denyLobbyUser(participantID)
        }
    }

    /// Sends a structured lobby message; `participantID == nil` broadcasts to moderators.
    public func sendLobbyMessage(
        _ message: [String: Any],
        to participantID: String?,
        completion: @escaping (NSError?) -> Void
    ) {
        signaling(completion: completion) { room in
            let data = try JSONSerialization.data(withJSONObject: message)
            try await room.sendLobbyMessage(try JSONValue(from: data), to: participantID)
        }
    }

    public func myLobbyUserID(completion: @escaping (String?) -> Void) {
        let room = conference
        Task {
            completion(try? await room?.myLobbyUserID())
        }
    }

    public func isAVModerationSupported(completion: @escaping (Bool) -> Void) {
        let room = conference
        Task {
            completion(await room?.isAVModerationSupported() ?? false)
        }
    }

    public func enableAVModeration(_ mediaType: String, completion: @escaping (NSError?) -> Void) {
        moderation(mediaType, completion: completion) { room, type in
            try await room.enableAVModeration(type)
        }
    }

    public func disableAVModeration(_ mediaType: String, completion: @escaping (NSError?) -> Void) {
        moderation(mediaType, completion: completion) { room, type in
            try await room.disableAVModeration(type)
        }
    }

    public func approveAVModeration(
        _ participantID: String,
        mediaType: String,
        completion: @escaping (NSError?) -> Void
    ) {
        moderation(mediaType, completion: completion) { room, type in
            try await room.approveAVModeration(participantID, mediaType: type)
        }
    }

    public func rejectAVModeration(
        _ participantID: String,
        mediaType: String,
        completion: @escaping (NSError?) -> Void
    ) {
        moderation(mediaType, completion: completion) { room, type in
            try await room.rejectAVModeration(participantID, mediaType: type)
        }
    }

    // MARK: - Breakout rooms

    /// Room rows for the moderator UI: `id`, `jid`, `name`, `isMainRoom`, `participants`.
    public func breakoutRooms() -> [[String: Any]] {
        conference?.breakoutRooms.map(Self.breakoutRoomDictionary) ?? []
    }

    /// Capability flags: `isSupported`, `canRename`, `isBreakoutRoom`, `canManage`,
    /// `mainRoomJID` (only while in a breakout) and `roomCounter`.
    public func breakoutRoomsState() -> [String: Any] {
        guard let conference else { return [:] }
        var state: [String: Any] = [
            "isSupported": conference.breakoutRoomsSupported,
            "canRename": conference.canRenameBreakoutRooms,
            "isBreakoutRoom": conference.isInBreakoutRoom,
            "canManage": conference.canManageBreakoutRooms,
            "roomCounter": conference.breakoutRoomCounter
        ]
        if let mainRoomJID = conference.breakoutMainRoomJID {
            state["mainRoomJID"] = mainRoomJID
        }
        return state
    }

    public func createBreakoutRoom(_ subject: String, completion: @escaping (NSError?) -> Void) {
        signaling(completion: completion) { room in
            try await room.createBreakoutRoom(subject: subject)
        }
    }

    public func renameBreakoutRoom(
        _ roomJID: String,
        subject: String,
        completion: @escaping (NSError?) -> Void
    ) {
        signaling(completion: completion) { room in
            try await room.renameBreakoutRoom(roomJID, subject: subject)
        }
    }

    public func removeBreakoutRoom(_ roomJID: String, completion: @escaping (NSError?) -> Void) {
        signaling(completion: completion) { room in
            try await room.removeBreakoutRoom(roomJID)
        }
    }

    /// Moves another participant. Pass this endpoint's own id to move yourself, which then
    /// arrives back as a `breakoutRoomsMoveToRoom` event and is followed automatically.
    public func sendParticipant(
        _ participantID: String,
        toBreakoutRoom roomJID: String,
        completion: @escaping (NSError?) -> Void
    ) {
        signaling(completion: completion) { room in
            try await room.sendParticipant(participantID, toBreakoutRoom: roomJID)
        }
    }

    /// Local switch into a breakout room, matching jitsi-meet's `moveToRoom`.
    public func switchToBreakoutRoom(_ roomJID: String, completion: @escaping (NSError?) -> Void) {
        guard !roomJID.isEmpty else {
            completion(Self.nsError(JitsiError.invalidArgument("a room JID is required")))
            return
        }
        guard let target = options(forRoomJID: roomJID) else {
            completion(Self.nsError(JitsiError.invalidArgument("unknown room: \(roomJID)")))
            return
        }
        switchRoom(to: target, completion: completion)
    }

    /// "Leave breakout": the same switch addressed at the room passed to `joinRoom`.
    public func returnToMainRoom(completion: @escaping (NSError?) -> Void) {
        guard let mainJoin else {
            completion(Self.nsError(JitsiError.notInConference))
            return
        }
        switchRoom(to: mainJoin, completion: completion)
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
        var state: [String: Any] = [
            "isModerator": conference.isModerator,
            "lobbySupported": conference.lobbySupported,
            "lobbyEnabled": conference.lobbyEnabled,
            "authRequired": conference.authRequired,
            "passwordRequired": conference.passwordRequired,
            "isLocked": conference.isLocked,
            "canEndConference": conference.canEndConference,
            "e2eeEnabled": conference.e2eeEnabled,
            "visitorsSupported": conference.visitorsSupported,
            "localParticipantProperties": conference.localParticipantProperties.mapValues(Self.anyValue),
            "conferenceProperties": conference.conferenceProperties.mapValues(Self.anyValue),
            "lobbyUsers": conference.lobbyUsers.values.map(Self.lobbyUserDictionary),
            "avModeration": Dictionary(
                uniqueKeysWithValues: conference.avModeration.map { ($0.key.rawValue, $0.value) }),
            "breakoutRooms": breakoutRooms(),
            "breakoutRoomsState": breakoutRoomsState()
        ]
        if let localParticipantID = conference.localParticipantID {
            state["myUserId"] = localParticipantID
        }
        if let policy = conference.startMutedPolicy {
            state["startMutedPolicy"] = ["audio": policy.audio, "video": policy.video]
        }
        return state
    }

    /// Lobby rows: `id`, `displayName`, optional `email`/`avatarURL`.
    public func lobbyUsers() -> [[String: Any]] {
        conference?.lobbyUsers.values.map(Self.lobbyUserDictionary) ?? []
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

    private func moderation(
        _ mediaType: String,
        completion: @escaping (NSError?) -> Void,
        _ body: @escaping (JitsiConference, AVModerationMediaType) async throws -> Void
    ) {
        guard let type = AVModerationMediaType(rawValue: mediaType) else {
            completion(Self.nsError(JitsiError.invalidArgument("mediaType must be audio, video or desktop")))
            return
        }
        signaling(completion: completion) { room in
            try await body(room, type)
        }
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
        lobbyKnockTask?.cancel()
        lobbyKnockTask = nil
        isWaitingInLobby = false
        isWaitingForHost = false
        requiresPassword = false
    }

    /// Target options for a room JID. A breakout JID lives on the component's own MUC, so it
    /// is split into name + custom domain; a JID on the main room's domain maps back to the
    /// options `joinRoom` took.
    private func options(forRoomJID roomJID: String) -> ConferenceOptions? {
        guard let current = lastJoin?.options, let mainJoin, let connectionOptions else { return nil }
        let mainDomain = mainJoin.configOverwrite["customDomain"]?.stringValue
            ?? connectionOptions.hosts.muc
        if roomJID.hasSuffix("@" + mainDomain) {
            return mainJoin
        }
        return try? current.room(atJID: roomJID)
    }

    private var currentRoomJID: String? {
        guard let current = lastJoin?.options, let connectionOptions else { return nil }
        let domain = current.configOverwrite["customDomain"]?.stringValue
            ?? connectionOptions.hosts.muc
        return "\(current.name)@\(domain)"
    }

    private func switchRoom(to options: ConferenceOptions, completion: @escaping (NSError?) -> Void) {
        guard let conference else {
            completion(Self.nsError(JitsiError.notInConference))
            return
        }
        guard switchTask == nil else {
            completion(Self.nsError(JitsiError.invalidArgument("a room switch is already in progress")))
            return
        }
        // The rejoin path follows `lastJoin`, so point it at the target before the old room
        // is released; a failure after that point must recover into the target room.
        if let join = lastJoin {
            lastJoin = (options, join.audio, join.video)
        }
        isSwitchingRoom = true
        publishState()
        switchTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.switchTask = nil
                self.isSwitchingRoom = false
            }
            do {
                try await conference.switchRoom(to: options)
                // Fresh presence in the new room: re-apply the mute choices to the tracks
                // that were carried over.
                if self.isAudioMuted { try? await conference.setMuted(true, mediaType: .audio) }
                if self.isVideoMuted { try? await conference.setMuted(true, mediaType: .video) }
                self.isJoined = true
                self.hasJoined = true
                self.publishState()
                completion(nil)
            } catch {
                self.lastError = "Room switch failed: \(error.localizedDescription)"
                self.publishState()
                completion(Self.nsError(error))
                self.scheduleRejoin()
            }
        }
    }

    /// Upstream default: a moderator's move is honored without asking the user.
    private func followBreakoutMove(to roomJID: String) {
        guard !roomJID.isEmpty, roomJID != currentRoomJID else { return }
        guard let target = options(forRoomJID: roomJID) else {
            lastError = "Unknown room: \(roomJID)"
            publishState()
            return
        }
        switchRoom(to: target) { _ in }
    }

    /// Full rejoin, the same recovery a jitsi-meet browser performs on `CONNECTION_DROPPED`:
    /// the BOSH session is gone, so the connection, tracks and room are rebuilt from the
    /// options of the last successful join, then the user's mute choices are re-applied.
    private func scheduleRejoin() {
        guard let join = lastJoin, let connection = connectionOptions, rejoinTask == nil else { return }
        // The rebuild replaces the conference, so a lobby knock in flight is gone with it.
        lobbyKnockTask?.cancel()
        lobbyKnockTask = nil
        isWaitingInLobby = false
        isWaitingForHost = false
        requiresPassword = false
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
                // The room switched to members-only while this endpoint was away; the
                // failure event knocks in the lobby, so the retry quota is not burned.
                if Self.isMembersOnlyFailure(error) {
                    return
                }
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

    /// Knocks in the room's lobby after a members-only failure, matching upstream
    /// jitsi-meet. The approval joins the same conference on its own, so `CONFERENCE_JOINED`
    /// is what clears the waiting state.
    private func knockOnLobby() {
        guard !isWaitingInLobby, let join = lastJoin, let room = conference else { return }
        isWaitingInLobby = true
        lastError = isWaitingForHost ? Self.waitingForHostMessage : Self.waitingForModeratorMessage
        publishState()
        let displayName = join.options.userInfo.displayName
        let email = join.options.userInfo.email ?? ""
        lobbyKnockTask = Task { [weak self] in
            guard let self else { return }
            defer { self.lobbyKnockTask = nil }
            do {
                try await room.joinLobby(displayName: displayName, email: email)
            } catch {
                guard !Task.isCancelled else { return }
                self.isWaitingInLobby = false
                self.isWaitingForHost = false
                self.lastError = error.localizedDescription
                self.publishState()
            }
        }
    }

    /// The wait-for-join wrapper prefixes the lib's error name, so this matches by
    /// containment instead of equality.
    private static func isMembersOnlyFailure(_ error: Error) -> Bool {
        guard let jitsiError = error as? JitsiError, case .remote(let detail) = jitsiError else {
            return false
        }
        return detail.contains(membersOnlyError)
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
            requiresPassword = false
            if isWaitingInLobby {
                isWaitingInLobby = false
                isWaitingForHost = false
                lastError = nil
                publishState()
            }
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
            isLocked = false
            isWaitingForHost = false
            requiresPassword = false
            lastError = reason
        case .lobbyWaitingForHost(let waiting):
            isWaitingForHost = waiting
            // The façade reports the flag before the failure, but a knock that resolved
            // first still gets the right wording when the flag arrives second.
            if isWaitingInLobby {
                lastError = waiting ? Self.waitingForHostMessage : Self.waitingForModeratorMessage
                publishState()
            }
        case .conferenceFailed(let error):
            isJoined = false
            requiresPassword = false
            if case .remote(let name) = error, name == Self.membersOnlyError {
                knockOnLobby()
            } else if case .remote(let name) = error, name == Self.accessDeniedError,
                      isWaitingInLobby {
                isWaitingInLobby = false
                isWaitingForHost = false
                lastError = "A moderator denied your request to join."
                publishState()
            } else if case .remote(let name) = error, name == Self.passwordRequiredError {
                isWaitingInLobby = false
                isWaitingForHost = false
                requiresPassword = true
                lastError = Self.passwordRequiredMessage
                publishState()
            } else {
                let wasWaiting = isWaitingInLobby
                isWaitingInLobby = false
                isWaitingForHost = false
                lastError = error.localizedDescription
                if wasWaiting { publishState() }
            }
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
             .participantRoleChanged, .participantPropertyChanged, .raisedHandChanged,
             .dominantSpeakerChanged, .conferencePropertiesChanged, .lobbyUserJoined,
             .lobbyUserUpdated, .lobbyUserLeft, .avModerationChanged, .avModerationApproved,
             .avModerationRejected, .avModerationParticipantApproved,
             .avModerationParticipantRejected, .breakoutRoomsUpdated:
            publishState()
        case .breakoutRoomsMoveToRoom(let roomJID):
            // Upstream default: follow the moderator's move automatically.
            followBreakoutMove(to: roomJID)
        case .connectionPropertiesUpdated(let properties):
            serverRegion = properties["region"]?.stringValue
            serverShard = properties["shard"]?.stringValue
            publishState()
        case .lockStateChanged(let locked):
            isLocked = locked
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
            "isSwitchingRoom": isSwitchingRoom,
            "isWaitingInLobby": isWaitingInLobby,
            "isWaitingForHost": isWaitingForHost,
            "requiresPassword": requiresPassword,
            "isNetworkOnline": isNetworkOnline,
            "isAudioMuted": isAudioMuted,
            "isVideoMuted": isVideoMuted,
            "isScreenSharing": isScreenSharing,
            "isLocked": isLocked,
            "e2eeEnabled": conference?.e2eeEnabled ?? false,
            "visitorsSupported": conference?.visitorsSupported ?? false,
            "participants": participants(),
            "localTracks": localTracks(),
            "remoteTracks": remoteTracks(),
            "breakoutRooms": breakoutRooms(),
            "breakoutRoomsState": breakoutRoomsState()
        ]
        if let lastError {
            snapshot["lastError"] = lastError
        }
        if let serverRegion {
            snapshot["serverRegion"] = serverRegion
        }
        if let serverShard {
            snapshot["serverShard"] = serverShard
        }
        return snapshot
    }

    private static func participantDictionary(_ participant: JitsiParticipant) -> [String: Any] {
        var row: [String: Any] = [
            "id": participant.id,
            "displayName": participant.displayName,
            "role": participant.role.rawValue,
            "raisedHand": participant.raisedHand,
            "properties": participant.snapshot.properties.mapValues(anyValue),
            "tracks": participant.snapshot.tracks.map(trackDictionary),
            "jid": participant.jid,
            "status": participant.status,
            "statsID": participant.statsID,
            "isSilent": participant.isSilent,
            "isReplacing": participant.isReplacing,
            "isReplaced": participant.isReplaced,
            "isHidden": participant.isHidden,
            "isAudioMuted": participant.isAudioMuted,
            "isVideoMuted": participant.isVideoMuted
        ]
        if let avatarURL = participant.avatarURL {
            row["avatarURL"] = avatarURL
        }
        if let email = participant.email {
            row["email"] = email
        }
        if let connectionJID = participant.connectionJID {
            row["connectionJID"] = connectionJID
        }
        if let botType = participant.botType {
            row["botType"] = botType
        }
        return row
    }

    private static func speakerStatsDictionary(_ stats: SpeakerStats) -> [String: Any] {
        [
            "participantId": stats.participantID,
            "displayName": stats.displayName,
            "isLocal": stats.isLocal,
            "isDominantSpeaker": stats.isDominantSpeaker,
            "totalDominantSpeakerTime": stats.totalDominantSpeakerTime,
            "hasLeft": stats.hasLeft,
            "faceLandmarks": stats.faceLandmarks.map { landmark in
                ["duration": landmark.duration, "faceExpression": landmark.faceExpression]
            }
        ]
    }

    private static func lobbyUserDictionary(_ user: LobbyUser) -> [String: Any] {
        var row: [String: Any] = [
            "id": user.id,
            "displayName": user.displayName
        ]
        if let email = user.email {
            row["email"] = email
        }
        if let avatarURL = user.avatarURL {
            row["avatarURL"] = avatarURL
        }
        return row
    }

    private static func breakoutRoomDictionary(_ room: BreakoutRoom) -> [String: Any] {
        [
            "id": room.id,
            "jid": room.jid,
            "name": room.name,
            "isMainRoom": room.isMainRoom,
            "participants": room.participants.map { participant in
                [
                    "jid": participant.jid,
                    "displayName": participant.displayName,
                    "role": participant.role.rawValue
                ]
            }
        ]
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

    private static func dictionary(for capabilities: VideoTrackCapabilities) -> [String: Any] {
        var result: [String: Any] = [
            "formats": capabilities.formats.map { format in
                [
                    "width": format.width,
                    "height": format.height,
                    "minFrameRate": format.minFrameRate,
                    "maxFrameRate": format.maxFrameRate
                ] as [String: Any]
            }
        ]
        if let deviceID = capabilities.deviceID {
            result["deviceId"] = deviceID
        }
        if let width = capabilities.activeWidth {
            result["activeWidth"] = width
        }
        if let height = capabilities.activeHeight {
            result["activeHeight"] = height
        }
        if let frameRate = capabilities.activeFrameRate {
            result["activeFrameRate"] = frameRate
        }
        return result
    }

    private static func jsonValue(_ value: Any) throws -> JSONValue {
        guard JSONSerialization.isValidJSONObject(["value": value]) else {
            throw JitsiError.invalidArgument(
                "property values must be a JSON string, number, boolean or array")
        }
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        return try JSONValue(from: data)
    }

    private static func anyValue(_ value: JSONValue) -> Any {
        switch value {
        case .null: return NSNull()
        case .bool(let flag): return flag
        case .number(let number): return number
        case .string(let text): return text
        case .array(let values): return values.map(anyValue)
        case .object(let entries): return entries.mapValues(anyValue)
        }
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
        case .lobbyWaitingForHost: return "lobbyWaitingForHost"
        case .participantJoined: return "participantJoined"
        case .participantLeft: return "participantLeft"
        case .participantDisplayNameChanged: return "participantDisplayNameChanged"
        case .participantAvatarChanged: return "participantAvatarChanged"
        case .participantEmailChanged: return "participantEmailChanged"
        case .participantRoleChanged: return "participantRoleChanged"
        case .participantPropertyChanged: return "participantPropertyChanged"
        case .conferencePropertiesChanged: return "conferencePropertiesChanged"
        case .connectionPropertiesUpdated: return "connectionPropertiesUpdated"
        case .lobbyUserJoined: return "lobbyUserJoined"
        case .lobbyUserUpdated: return "lobbyUserUpdated"
        case .lobbyUserLeft: return "lobbyUserLeft"
        case .lobbyMessageReceived: return "lobbyMessageReceived"
        case .avModerationChanged: return "avModerationChanged"
        case .avModerationApproved: return "avModerationApproved"
        case .avModerationRejected: return "avModerationRejected"
        case .avModerationParticipantApproved: return "avModerationParticipantApproved"
        case .avModerationParticipantRejected: return "avModerationParticipantRejected"
        case .breakoutRoomsUpdated: return "breakoutRoomsUpdated"
        case .breakoutRoomsMoveToRoom: return "breakoutRoomsMoveToRoom"
        case .participantMuted: return "participantMuted"
        case .raisedHandChanged: return "raisedHandChanged"
        case .lockStateChanged: return "lockStateChanged"
        case .conferenceCreatedTimestamp: return "conferenceCreatedTimestamp"
        case .conferenceJoinInProgress: return "conferenceJoinInProgress"
        case .conferenceUniqueIDSet: return "conferenceUniqueIDSet"
        case .conferenceConnectionEstablished: return "conferenceConnectionEstablished"
        case .audioUnmutePermissionsChanged: return "audioUnmutePermissionsChanged"
        case .videoUnmutePermissionsChanged: return "videoUnmutePermissionsChanged"
        case .visitorCodecsChanged: return "visitorCodecsChanged"
        case .botTypeChanged: return "botTypeChanged"
        case .permissionsReceived: return "permissionsReceived"
        case .silentStatusChanged: return "silentStatusChanged"
        case .membersOnlyChanged: return "membersOnlyChanged"
        case .visitorsSupportedChanged: return "visitorsSupportedChanged"
        case .phoneNumberChanged: return "phoneNumberChanged"
        case .fileSharingFileAdded: return "fileSharingFileAdded"
        case .fileSharingFileRemoved: return "fileSharingFileRemoved"
        case .visitorsMessage: return "visitorsMessage"
        case .visitorsRejection: return "visitorsRejection"
        case .bridgeBweStatsReceived: return "bridgeBweStatsReceived"
        case .endpointStatsReceived: return "endpointStatsReceived"
        case .encodeTimeStatsReceived: return "encodeTimeStatsReceived"
        case .inboundVideoStatsReceived: return "inboundVideoStatsReceived"
        case .beforeStatisticsDisposed: return "beforeStatisticsDisposed"
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
        case .commandReceived: return "commandReceived"
        case .reactionReceived: return "reactionReceived"
        case .recordingStateChanged: return "recordingStateChanged"
        case .e2EEStateChanged: return "e2eeStateChanged"
        case .kick: return "participantKicked"
        case .selfKicked: return "kicked"
        case .localMutedByFocus: return "localMutedByFocus"
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
        case .participantPropertyChanged(let id, let key, let value, let previous):
            return [
                "id": id, "key": key, "value": convert(value),
                "previous": previous.map(convert) ?? NSNull()
            ]
        case .conferencePropertiesChanged(let properties):
            return ["properties": convert(properties)]
        case .connectionPropertiesUpdated(let properties):
            return ["region": properties["region"]?.stringValue ?? "",
                    "shard": properties["shard"]?.stringValue ?? ""]
        case .lobbyUserJoined(let user), .lobbyUserUpdated(let user):
            var payload: [String: Any] = ["id": user.id, "displayName": user.displayName]
            payload["email"] = user.email ?? NSNull()
            payload["avatarURL"] = user.avatarURL ?? NSNull()
            return payload
        case .lobbyUserLeft(let id):
            return ["id": id]
        case .lobbyMessageReceived(let from, let message):
            return ["from": from ?? "", "message": convert(message)]
        case .avModerationChanged(let enabled, let mediaType, let actor):
            return ["enabled": enabled, "mediaType": mediaType?.rawValue ?? "", "actor": actor ?? ""]
        case .avModerationApproved(let mediaType), .avModerationRejected(let mediaType):
            return ["mediaType": mediaType.rawValue]
        case .avModerationParticipantApproved(let id, let mediaType),
             .avModerationParticipantRejected(let id, let mediaType):
            return ["id": id, "mediaType": mediaType.rawValue]
        case .breakoutRoomsUpdated(let state):
            return [
                "rooms": state.rooms.map { room in
                    [
                        "id": room.id,
                        "jid": room.jid,
                        "name": room.name,
                        "isMainRoom": room.isMainRoom,
                        "participants": room.participants.map { participant in
                            [
                                "jid": participant.jid,
                                "displayName": participant.displayName,
                                "role": participant.role.rawValue
                            ]
                        }
                    ] as [String: Any]
                },
                "roomCounter": state.roomCounter
            ]
        case .breakoutRoomsMoveToRoom(let roomJID):
            return ["roomJid": roomJID]
        case .commandReceived(let name, let from, let values):
            return ["name": name, "from": from, "values": convert(values)]
        case .reactionReceived(let participantID, let reactions, let messageID):
            return ["id": participantID, "reactions": reactions, "messageId": messageID]
        case .chatMessage(let from, let text, let isPrivate):
            return ["from": from, "text": text, "isPrivate": isPrivate]
        case .endpointMessage(let from, let content):
            return ["from": from ?? "", "content": convert(content)]
        case .conferenceCreatedTimestamp(let timestamp):
            return ["timestamp": timestamp]
        case .conferenceJoinInProgress, .conferenceConnectionEstablished,
             .visitorsRejection, .beforeStatisticsDisposed:
            return [:]
        case .conferenceUniqueIDSet(let id):
            return ["id": id]
        case .audioUnmutePermissionsChanged(let reached):
            return ["audioLimitReached": reached]
        case .videoUnmutePermissionsChanged(let reached):
            return ["videoLimitReached": reached]
        case .visitorCodecsChanged(let codecs):
            return ["codecs": codecs]
        case .botTypeChanged(let id, let botType):
            return ["id": id, "botType": botType ?? NSNull()]
        case .permissionsReceived(let permissions):
            return ["permissions": convert(permissions)]
        case .silentStatusChanged(let id, let isSilent):
            return ["id": id, "isSilent": isSilent]
        case .membersOnlyChanged(let membersOnly):
            return ["membersOnly": membersOnly]
        case .visitorsSupportedChanged(let supported):
            return ["supported": supported]
        case .phoneNumberChanged(let number):
            return ["phoneNumber": number ?? NSNull()]
        case .fileSharingFileAdded(let file):
            return ["file": convert(file)]
        case .fileSharingFileRemoved(let id):
            return ["id": id]
        case .visitorsMessage(let message):
            return ["message": convert(message)]
        case .bridgeBweStatsReceived(let bandwidth):
            return ["bandwidth": bandwidth]
        case .endpointStatsReceived(let id, let stats):
            return ["id": id, "stats": convert(stats)]
        case .encodeTimeStatsReceived(let payload), .inboundVideoStatsReceived(let payload):
            return convert(payload) as? [String: Any] ?? [:]
        case .selfKicked(let actor, let reason, let replaced):
            return [
                "actor": actor ?? NSNull(),
                "reason": reason,
                "replaced": replaced
            ]
        case .localMutedByFocus(let mediaType, let isScreenShare, let actor):
            return [
                "mediaType": mediaType.rawValue,
                "desktop": isScreenShare,
                "actor": actor ?? NSNull()
            ]
        default:
            return [:]
        }
    }
}
