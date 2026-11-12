import Foundation
import JitsiCore
import JitsiMedia

/// `MeetingEngine` over lib-jitsi-meet running in JavaScriptCore.
///
/// Swift -> JS goes through `__sdkSettle`, which wraps `__sdkInvoke` and attaches the
/// promise callbacks in the same execution; JS -> Swift arrives on the `sdk.event`
/// channel and is reduced into `MeetingEvent`. Nothing in this file knows about
/// DOM, XMPP or SDP — that is the point of the boundary.
public final class JSMeetingEngine: MeetingEngine {
    private let host = JSCEngineHost()
    private let backend: MediaBackend
    private let environment: HostEnvironment
    private let logLevel: String
    private var debugSignaling: Bool
    private var networkMonitor: NetworkMonitor?

    /// Latest `NWPathMonitor` verdict. Read by the reconnect loop so an offline radio holds
    /// the retries instead of burning them, and mirrored to the lib via `setNetworkInfo`.
    public private(set) var isNetworkOnline = true

    public let events: AsyncStream<MeetingEvent>
    private var continuation: AsyncStream<MeetingEvent>.Continuation?

    /// Host the runtime was installed for (`location.host` in the shims). A conference aimed
    /// at a different host cannot run on this engine.
    public let hostName: String

    /// Track ids created natively, mirrored so mute can be resolved per media type.
    private var capturedTracks: [MediaType: TrackID] = [:]
    private var audioSessionActive = false

    public init(
        backend: MediaBackend,
        hostName: String,
        logLevel: String = "info",
        debugSignaling: Bool = false
    ) {
        self.backend = backend
        self.logLevel = logLevel
        self.debugSignaling = debugSignaling
        self.hostName = hostName
        environment = HostEnvironment.current(host: hostName, backendReady: !(backend is UnavailableMediaBackend))

        var captured: AsyncStream<MeetingEvent>.Continuation?
        events = AsyncStream(bufferingPolicy: .unbounded) { captured = $0 }
        continuation = captured
    }

    // MARK: - Lifecycle

    public func install() async throws {
        try await backend.prepare()
        try host.start(backend: backend, capabilities: backend.capabilities, environment: environment)
        host.setEventHandler { [weak self] name, payload in
            self?.reduce(name: name, payload: payload)
        }
        _ = try await host.invoke("lib.init", args: .object([
            "logLevel": .string(logLevel),
            "options": .object([:]),
            "debug": .bool(debugSignaling)
        ]))
        // NWPathMonitor reports the current path as soon as it starts, so the lib learns the
        // starting reachability without a separate query.
        let monitor = NetworkMonitor { [weak self] online in
            guard let self else { return }
            self.isNetworkOnline = online
            self.host.emit(channel: "network", "status", .object(["online": .bool(online)]))
            self.continuation?.yield(.networkChanged(online: online))
        }
        monitor.start()
        networkMonitor = monitor
    }

    public func dispose() async {
        networkMonitor?.stop()
        networkMonitor = nil
        host.setEventHandler(nil)
        _ = try? await host.invoke("lib.dispose", args: .object([:]))
        host.stop()
        await deactivateAudio()
        await backend.shutdown()
        continuation?.finish()
    }

    // MARK: - Connection

    public func connect(_ options: ConnectionOptions) async throws {
        var hosts: [String: JSONValue] = [
            "domain": .string(options.hosts.domain),
            "muc": .string(options.hosts.muc)
        ]
        if let anonymous = options.hosts.anonymousdomain, !anonymous.isEmpty {
            hosts["anonymousdomain"] = .string(anonymous)
        }
        if let bridge = options.hosts.bridge {
            hosts["bridge"] = .string(bridge)
        }
        var args: [String: JSONValue] = [
            "serviceUrl": .string(options.serviceUrl),
            "hosts": .object(hosts)
        ]
        if let token = options.token {
            args["token"] = .string(token)
        }
        if let credentials = options.credentials {
            args["credentials"] = .object([
                "username": .string(credentials.username),
                "password": .string(credentials.password)
            ])
        }
        var p2p: [String: JSONValue] = [
            "stunServers": .array(options.p2p.stunServers.map { .object(["urls": .string($0)]) })
        ]
        if let policy = options.p2p.iceTransportPolicy {
            p2p["iceTransportPolicy"] = .string(policy.rawValue)
        }
        args["p2p"] = .object(p2p)
        // The JS side settles this promise on CONNECTION_ESTABLISHED, so returning here means
        // the XMPP socket is usable; the status event itself comes from `wireConnection`.
        _ = try await host.invoke("connection.connect", args: .object(args))
    }

    public func disconnect() async {
        _ = try? await host.invoke("connection.disconnect", args: .object([:]))
        // The facade disposed the tracks with the connection, so the mirrored ids are stale;
        // mute would otherwise reach for a track the JS side no longer knows.
        capturedTracks.removeAll()
        await deactivateAudio()
    }

    public func resetForRejoin() async {
        _ = try? await host.invoke("connection.disconnect", args: .object([:]))
        capturedTracks.removeAll()
        // Deliberately keeps the audio session: a rejoin is usually seconds away, and the
        // deactivate/activate pair resets the route and can interrupt other audio. The full
        // `disconnect()` and `leaveConference()` still release it.
    }

    /// Hands lib-jitsi-meet a fresh JWT while it is resuming an interrupted XMPP stream.
    /// Call this after `tokenExpired` fires; without it the resume attempt is cancelled.
    public func refreshToken(_ token: String) async throws {
        _ = try await host.invoke("connection.refreshToken", args: .object(["token": .string(token)]))
    }

    public func connectionJID() async throws -> String? {
        try await host.invoke("connection.jid", args: .object([:])).stringValue
    }

    public func connectionTimes() async throws -> JSONValue {
        try await host.invoke("connection.times", args: .object([:]))
    }

    public func addConnectionFeature(_ feature: String, submit: Bool) async throws {
        _ = try await host.invoke("connection.addFeature", args: .object([
            "feature": .string(feature), "submit": .bool(submit)
        ]))
    }

    public func removeConnectionFeature(_ feature: String, submit: Bool) async throws {
        _ = try await host.invoke("connection.removeFeature", args: .object([
            "feature": .string(feature), "submit": .bool(submit)
        ]))
    }

    public func attachConnection(rid: String, sid: String, jid: String) async throws {
        _ = try await host.invoke("connection.attach", args: .object([
            "rid": .string(rid), "sid": .string(sid), "jid": .string(jid)
        ]))
    }

    public func connectionLogs() async throws -> JSONValue {
        try await host.invoke("connection.logs", args: .object([:]))
    }

    // MARK: - Conference

    /// Creates the conference without joining it, so local tracks can be attached first.
    /// A conference that already contains its tracks answers the JVB session-initiate with
    /// audio/video m-lines the bridge can forward; adding them afterwards leaves the native
    /// senders empty until a track replacement happens.
    public func prepareConference(_ options: ConferenceOptions) async throws {
        _ = try await host.invoke("conference.prepare", args: .object(
            try Self.conferenceArguments(options)))
    }

    public func joinConference(_ options: ConferenceOptions, waitForJoin timeout: TimeInterval?) async throws {
        // Playout starts as soon as the first remote audio arrives, so the session has to be
        // live before the JVB answer. Capturing audio usually activates it earlier via
        // `openCapture`; this call covers listener-only joins.
        try await activateAudio()
        var args = try Self.conferenceArguments(options)
        if let password = options.password, !password.isEmpty {
            args["password"] = .string(password)
        }
        if let timeout {
            args["waitForJoin"] = .bool(true)
            args["waitTimeout"] = .number(timeout * 1000)
        }
        // The facade stages nick/avatar-url/email and the extras on the room before calling
        // conference.join(), so the first presence stanza already carries them. Setting the
        // display name afterwards would cost a second presence round-trip and briefly show
        // the participant under the server-assigned name.
        _ = try await host.invoke("conference.join", args: .object(args))
    }

    /// Leaves the current MUC with `switch_room` and joins `options` on the same connection.
    /// The audio session stays up and the facade re-adds the local tracks to the new
    /// conference, so a breakout round-trip does not flash the camera or drop the route.
    public func switchConference(to options: ConferenceOptions) async throws {
        try await activateAudio()
        var args = try Self.conferenceArguments(options)
        if let password = options.password, !password.isEmpty {
            args["password"] = .string(password)
        }
        args["waitForJoin"] = .bool(true)
        args["waitTimeout"] = .number(15_000)
        _ = try await host.invoke("conference.switch", args: .object(args))
    }

    private static func conferenceArguments(_ options: ConferenceOptions) throws -> [String: JSONValue] {
        // initJitsiConference(name, options) maps `options` straight onto the conference
        // config, so configOverwrite is merged rather than nested.
        for key in options.userInfo.extras.keys.sorted() where !Self.isPresenceName(key) {
            throw JitsiError.invalidArgument(
                "UserInfo.extras key '\(key)' is not a usable presence element name")
        }
        var config = options.configOverwrite
        config["startAudioOnly"] = .bool(false)
        return [
            "name": .string(options.name),
            "options": .object(options.connectionOptions.objectValue),
            "configOverwrite": .object(config),
            "userInfo": Self.userInfoJSON(options.userInfo)
        ]
    }

    static func userInfoJSON(_ userInfo: UserInfo) -> JSONValue {
        var object: [String: JSONValue] = ["displayName": .string(userInfo.displayName)]
        if let email = userInfo.email, !email.isEmpty {
            object["email"] = .string(email)
        }
        if let avatarURL = userInfo.avatarURL, !avatarURL.isEmpty {
            object["avatarURL"] = .string(avatarURL)
        }
        if !userInfo.extras.isEmpty {
            object["extras"] = .object(userInfo.extras.mapValues { .string($0) })
        }
        return .object(object)
    }

    /// XML NCName restricted to ASCII, matching what Strophe's element builder accepts.
    private static func isPresenceName(_ key: String) -> Bool {
        guard let first = key.first, first.isASCII, first.isLetter || first == "_" else {
            return false
        }
        return key.dropFirst().allSatisfy { character in
            character.isASCII
                && (character.isLetter || character.isNumber || character == "_"
                    || character == "-" || character == ".")
        }
    }

    public func leaveConference() async {
        _ = try? await host.invoke("conference.leave", args: .object([:]))
        await deactivateAudio()
    }

    // MARK: - Audio session

    /// Activates `AVAudioSession` (playAndRecord/voiceChat) and then tells WebRTC's manual
    /// audio wrapper about it. Idempotent: capture, join and rejoin all funnel through here.
    private func activateAudio() async throws {
        guard !audioSessionActive else { return }
        try await backend.activateAudioSession(preferSpeaker: true)
        audioSessionActive = true
    }

    private func deactivateAudio() async {
        guard audioSessionActive else { return }
        audioSessionActive = false
        await backend.deactivateAudioSession()
    }

    // MARK: - Media

    public func openCapture(_ mediaTypes: [MediaType], deviceIDs: [String: String]) async throws -> [TrackSnapshot] {
        // The local audio track is created here; the device module needs a live session
        // before `getUserMedia` reaches libwebrtc, not just before joining.
        if mediaTypes.contains(.audio) {
            try await activateAudio()
        }
        var constraints: [String: JSONValue] = [:]
        for mediaType in mediaTypes {
            let key = mediaType == .audio ? "audio" : "video"
            if let deviceID = deviceIDs[key] {
                constraints[key] = .object(["deviceId": .object(["exact": .string(deviceID)])])
            } else {
                constraints[key] = .bool(true)
            }
        }
        // The facade asks lib-jitsi-meet for local tracks; that call re-enters the shim
        // and lands in MediaModule, which owns the actual AVCaptureSession.
        let result = try await host.invoke("conference.createLocalTracks", args: .object([
            "options": .object([
                "devices": .array(mediaTypes.map { .string($0 == .audio ? "audio" : "video") }),
                "resolution": .number(720)
            ]),
            "constraints": .object(constraints)
        ]))
        let snapshots = result.trackSnapshots()
        for snapshot in snapshots {
            capturedTracks[snapshot.mediaType] = snapshot.id
        }
        return snapshots
    }

    public func closeCapture(_ trackIDs: [TrackID]) async throws {
        for mediaType in capturedTracks.keys {
            if let id = capturedTracks[mediaType], trackIDs.contains(id) {
                capturedTracks.removeValue(forKey: mediaType)
            }
        }
        await backend.stopCapture(trackIDs)
    }

    public func attachTracks(_ trackIDs: [TrackID]) async throws {
        for trackID in trackIDs {
            _ = try await host.invoke("conference.addTrack", args: .object(["trackId": .string(trackID)]))
        }
    }

    public func detachTracks(_ trackIDs: [TrackID]) async throws {
        for trackID in trackIDs {
            _ = try await host.invoke("conference.removeTrack", args: .object(["trackId": .string(trackID)]))
        }
    }

    public func setMuted(_ muted: Bool, mediaType: MediaType) async throws {
        guard let trackID = capturedTracks[mediaType] else {
            throw JitsiError.noLocalTrack(mediaType)
        }
        _ = try await host.invoke("conference.setMuted", args: .object([
            "trackId": .string(trackID),
            "muted": .bool(muted),
            "mediaType": .string(mediaType.rawValue)
        ]))
    }

    public func applyReceivePolicy(maxHeight: Int, lastN: Int) async throws {
        _ = try await host.invoke("conference.setReceiverVideoConstraint", args: .object([
            "maxHeight": .number(Double(maxHeight))
        ]))
        _ = try await host.invoke("conference.setLastN", args: .object([
            "lastN": .number(Double(max(1, lastN)))
        ]))
    }

    public func setReceiverConstraints(_ constraints: ReceiverConstraints) async throws {
        var args: [String: JSONValue] = [:]
        if let lastN = constraints.lastN {
            args["lastN"] = .number(Double(lastN))
        }
        if let height = constraints.defaultMaxHeight {
            args["defaultMaxHeight"] = .number(Double(height))
        }
        if !constraints.sourceMaxHeights.isEmpty {
            args["sourceMaxHeights"] = .object(
                constraints.sourceMaxHeights.mapValues { .number(Double($0)) })
        }
        if let bps = constraints.assumedBandwidthBps {
            args["assumedBandwidthBps"] = .number(Double(bps))
        }
        _ = try await host.invoke("conference.setReceiverConstraints", args: .object(args))
    }

    public func setAssumedBandwidthBps(_ bps: Int) async throws {
        _ = try await host.invoke("conference.setAssumedBandwidthBps", args: .object([
            "bps": .number(Double(bps))
        ]))
    }

    public func setDesktopSharingFrameRate(_ maxFps: Int) async throws -> Bool {
        let result = try await host.invoke("conference.setDesktopSharingFrameRate", args: .object([
            "maxFps": .number(Double(maxFps))
        ]))
        return result.boolValue ?? false
    }

    public func replaceTrack(old: TrackID?, new: TrackID?) async throws -> TrackSnapshot? {
        guard old != nil || new != nil else {
            throw JitsiError.invalidArgument("replaceTrack needs an old or a new track")
        }
        let result = try await host.invoke("conference.replaceTrack", args: .object([
            "oldTrackId": old.map(JSONValue.string) ?? .null,
            "newTrackId": new.map(JSONValue.string) ?? .null
        ]))
        let snapshot: TrackSnapshot?
        if case .null = result {
            snapshot = nil
        } else {
            snapshot = result.trackSnapshot()
        }
        // Mute resolves by media type through this map; keep it pointing at the live track.
        if let old {
            let affected = capturedTracks.filter { $0.value == old }.map(\.key)
            for mediaType in affected {
                if let snapshot {
                    capturedTracks[mediaType] = snapshot.id
                } else {
                    capturedTracks[mediaType] = nil
                }
            }
        }
        return snapshot
    }

    public func setVideoQuality(_ height: Int) async throws {
        _ = try await host.invoke("conference.setLocalVideoQuality", args: .object(["height": .number(Double(height))]))
    }

    public func videoCapabilities(for trackID: TrackID) async throws -> VideoTrackCapabilities {
        let result = try await host.invoke("conference.videoCapabilities", args: .object([
            "trackId": .string(trackID)
        ]))
        return Self.videoCapabilities(from: result)
    }

    public func applyVideoConstraints(
        _ constraints: VideoConstraints,
        to trackID: TrackID
    ) async throws -> VideoTrackCapabilities {
        var raw: [String: JSONValue] = ["trackId": .string(trackID)]
        if let width = constraints.width {
            raw["width"] = .number(Double(width))
        }
        if let height = constraints.height {
            raw["height"] = .number(Double(height))
        }
        if let frameRate = constraints.frameRate {
            raw["frameRate"] = .number(Double(frameRate))
        }
        let result = try await host.invoke("conference.applyVideoConstraints", args: .object([
            "trackId": .string(trackID),
            "constraints": .object(raw)
        ]))
        let capabilities = Self.videoCapabilities(from: result)
        // lib-jitsi-meet has its own outgoing size cap; without pushing the new height the
        // capture would change but the sender would keep the old resolution.
        if let height = capabilities.activeHeight {
            _ = try? await host.invoke("conference.setLocalVideoQuality", args: .object([
                "height": .number(Double(height))
            ]))
        }
        return capabilities
    }

    private static func videoCapabilities(from value: JSONValue) -> VideoTrackCapabilities {
        let formats = value["formats"]?.arrayValue.compactMap { item -> VideoTrackCapabilities.Format? in
            guard let width = item["width"]?.intValue, let height = item["height"]?.intValue else {
                return nil
            }
            return VideoTrackCapabilities.Format(
                width: width,
                height: height,
                minFrameRate: item["minFrameRate"]?.doubleValue ?? 0,
                maxFrameRate: item["maxFrameRate"]?.doubleValue ?? 0)
        } ?? []
        return VideoTrackCapabilities(
            formats: formats,
            activeWidth: value["activeWidth"]?.intValue,
            activeHeight: value["activeHeight"]?.intValue,
            activeFrameRate: value["activeFrameRate"]?.doubleValue,
            deviceID: value["deviceId"]?.stringValue)
    }

    public func startScreenShare() async throws -> TrackSnapshot {
        // `devices: ['desktop']` is lib-jitsi-meet's desktop path: it calls getDisplayMedia,
        // tags the resulting JitsiLocalTrack with VideoType.DESKTOP and sends the
        // screen-sharing presence that other participants render as a shared screen.
        let result = try await host.invoke("conference.createLocalTracks", args: .object([
            "options": .object(["devices": .array([.string("desktop")])])
        ]))
        guard let snapshot = result.trackSnapshots().first else {
            throw JitsiError.unsupported("screen sharing returned no track")
        }
        return snapshot
    }

    public func stopScreenShare() async {
        await backend.stopScreenShare()
    }

    public func switchCamera() async throws -> String {
        guard capturedTracks[.video] != nil else {
            throw JitsiError.noLocalTrack(.video)
        }
        return try await backend.switchCamera()
    }

    public func speakerStats() async throws -> [SpeakerStats] {
        let result = try await host.invoke("conference.speakerStats", args: .object([:]))
        return result.arrayValue.compactMap { $0.speakerStats() }
    }

    public func audioOutputRoute() async throws -> AudioOutputRoute {
        try await backend.audioOutput()
    }

    public func setAudioOutputRoute(_ route: AudioOutputRoute) async throws {
        try await backend.setAudioOutput(route)
    }

    public func runPreCallTest(_ iceServers: [PreCallTestServer]) async throws -> PreCallTestResult {
        let servers = iceServers.map { server -> JSONValue in
            var raw: [String: JSONValue] = [
                "urls": .array(server.urls.map { .string($0) })
            ]
            if let username = server.username {
                raw["username"] = .string(username)
            }
            if let credential = server.credential {
                raw["credential"] = .string(credential)
            }
            return .object(raw)
        }
        let result = try await host.invoke("lib.preCallTest", args: .object([
            "iceServers": .array(servers)
        ]))
        guard case .object = result else {
            throw JitsiError.remote("pre-call test returned \(result)")
        }
        return PreCallTestResult(
            mediaConnectivity: result["mediaConnectivity"]?.boolValue ?? false,
            throughput: result["throughput"]?.doubleValue,
            fractionalLoss: result["fractionalLoss"]?.doubleValue,
            rtt: result["rtt"]?.doubleValue,
            jitter: result["jitter"]?.doubleValue
        )
    }

    public func frameStream(for trackID: TrackID) -> AsyncStream<VideoPixelFrame> {
        backend.frameStream(for: trackID)
    }

    // MARK: - Signaling

    public func sendMessage(_ text: String, to participantID: ParticipantID?) async throws {
        _ = try await host.invoke("conference.sendMessage", args: .object([
            "text": .string(text),
            "to": participantID.map(JSONValue.string) ?? .null
        ]))
    }

    public func sendJSONMessage(_ payload: JSONValue, to participantID: ParticipantID?) async throws {
        guard case .object = payload else {
            throw JitsiError.invalidArgument("sendJSONMessage expects a JSON object")
        }
        _ = try await host.invoke("conference.sendJSONMessage", args: .object([
            "payload": payload,
            "to": participantID.map(JSONValue.string) ?? .null
        ]))
    }

    public func sendEndpointMessage(_ payload: JSONValue, to participantID: ParticipantID?) async throws {
        guard case .object = payload else {
            throw JitsiError.invalidArgument("sendEndpointMessage expects a JSON object")
        }
        _ = try await host.invoke("conference.sendEndpointMessage", args: .object([
            "payload": payload,
            "to": participantID.map(JSONValue.string) ?? .null
        ]))
    }

    public func sendCommand(_ name: String, values: [String: JSONValue]) async throws {
        _ = try await host.invoke("conference.sendCommand", args: .object([
            "name": .string(name),
            "values": .object(values)
        ]))
    }

    public func sendCommandOnce(_ name: String, values: [String: JSONValue]) async throws {
        _ = try await host.invoke("conference.sendCommandOnce", args: .object([
            "name": .string(name),
            "values": .object(values)
        ]))
    }

    public func removeCommand(_ name: String) async throws {
        _ = try await host.invoke("conference.removeCommand", args: .object(["name": .string(name)]))
    }

    public func addCommandListener(_ name: String) async throws {
        _ = try await host.invoke("conference.addCommandListener", args: .object(["name": .string(name)]))
    }

    public func removeCommandListener(_ name: String) async throws {
        _ = try await host.invoke("conference.removeCommandListener", args: .object(["name": .string(name)]))
    }

    public func sendReaction(_ reaction: String, messageID: String, to participantID: ParticipantID?) async throws {
        _ = try await host.invoke("conference.sendReaction", args: .object([
            "reaction": .string(reaction),
            "messageId": .string(messageID),
            "to": participantID.map(JSONValue.string) ?? .null
        ]))
    }

    public func setDisplayName(_ name: String) async throws {
        _ = try await host.invoke("conference.setDisplayName", args: .object(["name": .string(name)]))
    }

    public func authenticateAndUpgradeRole(id: String, password: String) async throws {
        _ = try await host.invoke("conference.authenticateAndUpgradeRole", args: .object([
            "id": .string(id), "password": .string(password)
        ]))
    }

    public func sendTones(_ tones: String, duration: Int, pause: Int) async throws {
        _ = try await host.invoke("conference.sendTones", args: .object([
            "tones": .string(tones),
            "duration": .number(Double(duration)),
            "pause": .number(Double(pause))
        ]))
    }

    public func isSIPCallingSupported() async throws -> Bool {
        try await host.invoke("conference.isSIPCallingSupported", args: .object([:])).boolValue ?? false
    }

    public func dial(_ number: String) async throws {
        _ = try await host.invoke("conference.dial", args: .object(["number": .string(number)]))
    }

    public func raiseHand(_ raised: Bool) async throws {
        // lib-jitsi-meet has no raise-hand API, but every client reads the
        // `jitsi_participant_raiseHand` presence extension, so the facade edits presence
        // through the lib's own setLocalParticipantProperty/removeLocalParticipantProperty.
        _ = try await host.invoke("conference.raiseHand", args: .object(["raised": .bool(raised)]))
    }

    public func kick(_ participantID: ParticipantID) async throws {
        _ = try await host.invoke("conference.kick", args: .object(["participantId": .string(participantID)]))
    }

    public func muteRemote(_ participantID: ParticipantID, mediaType: MediaType, mute: Bool) async throws {
        guard mute else {
            throw JitsiError.unsupported(
                "remote unmute: the participant must unmute, or a moderator can approve an AV-moderation request")
        }
        _ = try await host.invoke("conference.muteRemote", args: .object([
            "participantId": .string(participantID),
            "mediaType": .string(mediaType.rawValue),
            "mute": .bool(true)
        ]))
    }

    public func setRemoteAudioMuted(_ muted: Bool) async throws {
        _ = try await host.invoke("conference.setRemoteAudioSubscription", args: .object([
            "muted": .bool(muted)
        ]))
    }

    // MARK: - Conference control

    public func endConference() async throws {
        _ = try await host.invoke("conference.end", args: .object([:]))
    }

    public func lockConference(password: String) async throws {
        _ = try await host.invoke("conference.lock", args: .object([
            "password": .string(password)
        ]))
    }

    public func unlockConference() async throws {
        _ = try await host.invoke("conference.unlock", args: .object([:]))
    }

    public func grantOwner(_ participantID: ParticipantID) async throws {
        _ = try await host.invoke("conference.grantOwner", args: .object([
            "participantId": .string(participantID)
        ]))
    }

    public func revokeOwner(_ participantID: ParticipantID) async throws {
        _ = try await host.invoke("conference.revokeOwner", args: .object([
            "participantId": .string(participantID)
        ]))
    }

    public func setSilent(_ silent: Bool) async throws {
        _ = try await host.invoke("conference.setSilent", args: .object(["silent": .bool(silent)]))
    }

    public func setSubject(_ subject: String) async throws {
        _ = try await host.invoke("conference.setSubject", args: .object([
            "subject": .string(subject)
        ]))
    }

    public func setStartMutedPolicy(_ policy: StartMutedPolicy) async throws {
        _ = try await host.invoke("conference.setStartMutedPolicy", args: .object([
            "audio": .bool(policy.audio),
            "video": .bool(policy.video)
        ]))
    }

    // MARK: - Local participant properties

    public func setLocalParticipantProperty(_ name: String, value: JSONValue) async throws {
        _ = try await host.invoke("conference.setLocalParticipantProperty", args: .object([
            "name": .string(name),
            "value": value
        ]))
    }

    public func removeLocalParticipantProperty(_ name: String) async throws {
        _ = try await host.invoke("conference.removeLocalParticipantProperty", args: .object([
            "name": .string(name)
        ]))
    }

    public func localParticipantProperty(_ name: String) async throws -> JSONValue? {
        let value = try await host.invoke("conference.localParticipantProperty", args: .object([
            "name": .string(name)
        ]))
        if case .null = value {
            return nil
        }
        return value
    }

    public func enableLobby() async throws {
        _ = try await host.invoke("conference.enableLobby", args: .object([:]))
    }

    public func disableLobby() async throws {
        _ = try await host.invoke("conference.disableLobby", args: .object([:]))
    }

    public func joinLobby(displayName: String, email: String) async throws {
        _ = try await host.invoke("conference.joinLobby", args: .object([
            "displayName": .string(displayName),
            "email": .string(email)
        ]))
    }

    public func approveLobbyUser(_ participantID: ParticipantID) async throws {
        _ = try await host.invoke("conference.approveLobbyUser", args: .object([
            "participantId": .string(participantID)
        ]))
    }

    public func denyLobbyUser(_ participantID: ParticipantID) async throws {
        _ = try await host.invoke("conference.denyLobbyUser", args: .object([
            "participantId": .string(participantID)
        ]))
    }

    public func sendLobbyMessage(_ message: JSONValue, to participantID: ParticipantID?) async throws {
        var args: [String: JSONValue] = ["message": message]
        if let participantID {
            args["participantId"] = .string(participantID)
        }
        _ = try await host.invoke("conference.sendLobbyMessage", args: .object(args))
    }

    public func myLobbyUserID() async throws -> ParticipantID? {
        let value = try await host.invoke("conference.myLobbyUserID", args: .object([:]))
        return value.stringValue.flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: - AV moderation

    public func isAVModerationSupported() async throws -> Bool {
        try await host.invoke("conference.isAVModerationSupported", args: .object([:])).boolValue ?? false
    }

    public func enableAVModeration(_ mediaType: AVModerationMediaType) async throws {
        _ = try await host.invoke("conference.enableAVModeration", args: .object([
            "mediaType": .string(mediaType.rawValue)
        ]))
    }

    public func disableAVModeration(_ mediaType: AVModerationMediaType) async throws {
        _ = try await host.invoke("conference.disableAVModeration", args: .object([
            "mediaType": .string(mediaType.rawValue)
        ]))
    }

    public func approveAVModeration(_ participantID: ParticipantID, mediaType: AVModerationMediaType) async throws {
        _ = try await host.invoke("conference.approveAVModeration", args: .object([
            "participantId": .string(participantID),
            "mediaType": .string(mediaType.rawValue)
        ]))
    }

    public func rejectAVModeration(_ participantID: ParticipantID, mediaType: AVModerationMediaType) async throws {
        _ = try await host.invoke("conference.rejectAVModeration", args: .object([
            "participantId": .string(participantID),
            "mediaType": .string(mediaType.rawValue)
        ]))
    }

    // MARK: - Breakout rooms

    public func breakoutRoomsState() async throws -> BreakoutRoomsState {
        let value = try await host.invoke("conference.breakoutRoomsState", args: .object([:]))
        return value.breakoutRoomsState()
    }

    public func createBreakoutRoom(subject: String) async throws {
        _ = try await host.invoke("conference.createBreakoutRoom", args: .object([
            "subject": .string(subject)
        ]))
    }

    public func renameBreakoutRoom(_ roomJID: String, subject: String) async throws {
        _ = try await host.invoke("conference.renameBreakoutRoom", args: .object([
            "roomJid": .string(roomJID),
            "subject": .string(subject)
        ]))
    }

    public func removeBreakoutRoom(_ roomJID: String) async throws {
        _ = try await host.invoke("conference.removeBreakoutRoom", args: .object([
            "roomJid": .string(roomJID)
        ]))
    }

    public func sendParticipant(_ participantID: ParticipantID, toBreakoutRoom roomJID: String) async throws {
        _ = try await host.invoke("conference.sendParticipantToBreakoutRoom", args: .object([
            "participantId": .string(participantID),
            "roomJid": .string(roomJID)
        ]))
    }

    // MARK: - Sessions

    public func startRecording(_ options: RecordingOptions) async throws {
        var args: [String: JSONValue] = ["mode": .string(options.mode.rawValue)]
        if let key = options.youTubeStreamKey {
            args["streamKey"] = .string(key)
        }
        _ = try await host.invoke("conference.startRecording", args: .object(args))
    }

    public func stopRecording() async throws {
        _ = try await host.invoke("conference.stopRecording", args: .object([:]))
    }

    public func enableE2EE(key: String, password: String?) async throws {
        _ = try await host.invoke("conference.e2ee", args: .object([
            "enabled": .bool(true),
            "key": .string(key),
            "password": password.map(JSONValue.string) ?? .null
        ]))
    }

    public func disableE2EE() async throws {
        _ = try await host.invoke("conference.e2ee", args: .object(["enabled": .bool(false)]))
    }

    // MARK: - Product layer

    public func pollsSupported() async throws -> Bool {
        try await host.invoke("conference.pollsSupported", args: .object([:])).boolValue ?? false
    }

    public func createPoll(id: String, question: String, answers: [String]) async throws {
        _ = try await host.invoke("conference.createPoll", args: .object([
            "pollId": .string(id),
            "question": .string(question),
            "answers": .array(answers.map(JSONValue.string))
        ]))
    }

    public func answerPoll(id: String, answers: [Bool]) async throws {
        _ = try await host.invoke("conference.answerPoll", args: .object([
            "pollId": .string(id),
            "answers": .array(answers.map(JSONValue.bool))
        ]))
    }

    // MARK: - Diagnostics

    public func statisticsSnapshot() async throws -> JSONValue {
        try await host.invoke("conference.stats", args: .object([:]))
    }

    public func conferenceState() async throws -> JSONValue {
        try await host.invoke("conference.state", args: .object([:]))
    }

    public func setDebugSignaling(_ enabled: Bool) async {
        guard debugSignaling != enabled else { return }
        debugSignaling = enabled
        _ = try? await host.invoke("lib.setDebug", args: .object(["enabled": .bool(enabled)]))
    }

    // MARK: - Event reduction

    private func reduce(name: String, payload: JSONValue) {
        let event: MeetingEvent
        switch name {
        case "connectionStatus":
            let status = ConnectionStatus(rawValue: payload["status"]?.stringValue ?? "") ?? .error
            event = .connectionStatus(status, message: payload["error"]?.stringValue)
        case "connectionInterrupted":
            event = .connectionInterrupted
        case "connectionRestored":
            event = .connectionRestored
        case "connectionLost":
            event = .connectionLost(reason: payload["reason"]?.stringValue)
        case "tokenExpired":
            event = .tokenExpired(resumable: payload["resumable"]?.boolValue ?? false)
        case "conferenceJoined":
            event = .conferenceJoined(payload["id"]?.stringValue ?? "")
        case "conferenceLeft":
            event = .conferenceLeft(reason: payload["id"]?.stringValue)
        case "conferenceFailed":
            event = .conferenceFailed(.remote(payload["error"]?.stringValue ?? "conference failed"))
        case "lobbyWaitingForHost":
            event = .lobbyWaitingForHost(payload["waiting"]?.boolValue ?? false)
        case "participantJoined":
            event = .participantJoined(payload.participantSnapshot() ?? .empty(payload["id"]?.stringValue ?? ""))
        case "participantLeft":
            event = .participantLeft(payload.participantSnapshot() ?? .empty(payload["id"]?.stringValue ?? ""))
        case "participantDisplayNameChanged":
            event = .participantDisplayNameChanged(
                payload["id"]?.stringValue ?? "",
                payload["name"]?.stringValue ?? ""
            )
        case "participantAvatarChanged":
            event = .participantAvatarChanged(
                payload["id"]?.stringValue ?? "",
                payload["value"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            )
        case "participantEmailChanged":
            event = .participantEmailChanged(
                payload["id"]?.stringValue ?? "",
                payload["value"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            )
        case "participantRoleChanged":
            event = .participantRoleChanged(
                payload["id"]?.stringValue ?? "",
                ParticipantRole(rawValue: payload["role"]?.stringValue ?? "") ?? .none
            )
        case "participantMuted":
            event = .participantMuted(
                payload["id"]?.stringValue ?? "",
                MediaType(rawValue: payload["mediaType"]?.stringValue ?? "") ?? .audio,
                payload["muted"]?.boolValue ?? false
            )
        case "raisedHandChanged":
            event = .raisedHandChanged(payload["id"]?.stringValue ?? "", payload["raised"]?.boolValue ?? false)
        case "participantPropertyChanged":
            event = .participantPropertyChanged(
                payload["id"]?.stringValue ?? "",
                key: payload["key"]?.stringValue ?? "",
                value: payload["value"] ?? .null,
                previous: payload["previous"]
            )
        case "conferencePropertiesChanged":
            event = .conferencePropertiesChanged(payload)
        case "connectionPropertiesUpdated":
            event = .connectionPropertiesUpdated(payload)
        case "lobbyUserJoined":
            event = .lobbyUserJoined(payload.lobbyUser() ?? LobbyUser(id: payload["id"]?.stringValue ?? ""))
        case "lobbyUserUpdated":
            event = .lobbyUserUpdated(payload.lobbyUser() ?? LobbyUser(id: payload["id"]?.stringValue ?? ""))
        case "lobbyUserLeft":
            event = .lobbyUserLeft(payload["id"]?.stringValue ?? "")
        case "lobbyMessageReceived":
            event = .lobbyMessageReceived(
                from: payload["from"]?.stringValue,
                payload["message"] ?? .object([:])
            )
        case "avModerationChanged":
            event = .avModerationChanged(
                enabled: payload["enabled"]?.boolValue ?? false,
                mediaType: payload["mediaType"]?.moderationMediaType(),
                actor: payload["actor"]?.stringValue
            )
        case "avModerationApproved":
            if let mediaType = payload["mediaType"]?.moderationMediaType() {
                event = .avModerationApproved(mediaType)
            } else {
                event = .raw(name: name, payload)
            }
        case "avModerationRejected":
            if let mediaType = payload["mediaType"]?.moderationMediaType() {
                event = .avModerationRejected(mediaType)
            } else {
                event = .raw(name: name, payload)
            }
        case "avModerationParticipantApproved":
            if let mediaType = payload["mediaType"]?.moderationMediaType() {
                event = .avModerationParticipantApproved(payload["id"]?.stringValue ?? "", mediaType)
            } else {
                event = .raw(name: name, payload)
            }
        case "avModerationParticipantRejected":
            if let mediaType = payload["mediaType"]?.moderationMediaType() {
                event = .avModerationParticipantRejected(payload["id"]?.stringValue ?? "", mediaType)
            } else {
                event = .raw(name: name, payload)
            }
        case "breakoutRoomsUpdated":
            event = .breakoutRoomsUpdated(payload.breakoutRoomsState())
        case "breakoutRoomsMoveToRoom":
            event = .breakoutRoomsMoveToRoom(roomJID: payload["roomJid"]?.stringValue ?? "")
        case "lockStateChanged":
            event = .lockStateChanged(payload["locked"]?.boolValue ?? false)
        case "conferenceCreatedTimestamp":
            event = .conferenceCreatedTimestamp(payload["timestamp"]?.stringValue ?? "")
        case "conferenceJoinInProgress":
            event = .conferenceJoinInProgress
        case "conferenceUniqueIDSet":
            event = .conferenceUniqueIDSet(payload["id"]?.stringValue ?? "")
        case "conferenceConnectionEstablished":
            event = .conferenceConnectionEstablished
        case "audioUnmutePermissionsChanged":
            event = .audioUnmutePermissionsChanged(payload["audioLimitReached"]?.boolValue ?? false)
        case "videoUnmutePermissionsChanged":
            event = .videoUnmutePermissionsChanged(payload["videoLimitReached"]?.boolValue ?? false)
        case "visitorCodecsChanged":
            event = .visitorCodecsChanged(payload["codecs"]?.arrayValue.compactMap(\.stringValue) ?? [])
        case "botTypeChanged":
            event = .botTypeChanged(
                payload["id"]?.stringValue ?? "",
                payload["botType"]?.stringValue
            )
        case "permissionsReceived":
            event = .permissionsReceived(payload["permissions"] ?? .object([:]))
        case "silentStatusChanged":
            event = .silentStatusChanged(
                payload["id"]?.stringValue ?? "",
                payload["isSilent"]?.boolValue ?? false
            )
        case "membersOnlyChanged":
            event = .membersOnlyChanged(payload["membersOnly"]?.boolValue ?? false)
        case "visitorsSupportedChanged":
            event = .visitorsSupportedChanged(payload["supported"]?.boolValue ?? false)
        case "phoneNumberChanged":
            event = .phoneNumberChanged(payload["phoneNumber"]?.stringValue)
        case "fileSharingFileAdded":
            event = .fileSharingFileAdded(payload["file"] ?? .null)
        case "fileSharingFileRemoved":
            event = .fileSharingFileRemoved(payload["id"]?.stringValue ?? "")
        case "visitorsMessage":
            event = .visitorsMessage(payload["message"] ?? .null)
        case "visitorsRejection":
            event = .visitorsRejection
        case "bridgeBweStatsReceived":
            event = .bridgeBweStatsReceived(payload["bandwidth"]?.doubleValue ?? 0)
        case "endpointStatsReceived":
            event = .endpointStatsReceived(
                payload["id"]?.stringValue ?? "",
                payload["stats"] ?? .object([:])
            )
        case "encodeTimeStatsReceived":
            event = .encodeTimeStatsReceived(payload)
        case "inboundVideoStatsReceived":
            event = .inboundVideoStatsReceived(payload)
        case "beforeStatisticsDisposed":
            event = .beforeStatisticsDisposed
        case "dominantSpeakerChanged":
            event = .dominantSpeakerChanged(payload["id"]?.stringValue)
        case "localTrackAdded":
            event = .localTrackAdded(payload.trackSnapshot() ?? defaultTrack(payload))
        case "localTrackRemoved":
            event = .localTrackRemoved(payload.trackSnapshot() ?? defaultTrack(payload))
        case "remoteTrackAdded":
            event = .remoteTrackAdded(
                payload["track"]?.trackSnapshot() ?? defaultTrack(payload["track"] ?? .object([:])),
                payload["owner"]?.stringValue ?? ""
            )
        case "remoteTrackRemoved":
            event = .remoteTrackRemoved(
                payload["track"]?.trackSnapshot() ?? defaultTrack(payload["track"] ?? .object([:])),
                payload["owner"]?.stringValue ?? ""
            )
        case "trackMuteChanged":
            event = .trackMuteChanged(payload.trackSnapshot() ?? defaultTrack(payload))
        case "audioLevel":
            event = .audioLevels([payload["id"]?.stringValue ?? "": payload["level"]?.doubleValue ?? 0])
        case "localStats", "remoteStats":
            // `connectionQuality` is the digital level lib-jitsi-meet reports. The
            // good/fair/poor label is app-level in the lib, so it is left empty here.
            let isRemote = name == "remoteStats"
            let stats = isRemote ? (payload["stats"] ?? payload) : payload
            event = .connectionQualityLevel(
                digital: Int(stats["connectionQuality"]?.doubleValue ?? -1),
                summary: "",
                participantID: isRemote ? payload["id"]?.stringValue : nil
            )
        case "chatMessage":
            event = .chatMessage(
                from: payload["from"]?.stringValue ?? "",
                text: payload["text"]?.stringValue ?? "",
                isPrivate: payload["isPrivate"]?.boolValue ?? false
            )
        case "endpointMessage":
            event = .endpointMessage(from: payload["from"]?.stringValue, payload["content"] ?? .object([:]))
        case "commandReceived":
            event = .commandReceived(
                name: payload["name"]?.stringValue ?? "",
                from: payload["from"]?.stringValue ?? "",
                values: payload["values"] ?? .object([:])
            )
        case "reactionReceived":
            event = .reactionReceived(
                participantID: payload["id"]?.stringValue ?? "",
                reactions: payload["reactions"]?.arrayValue.compactMap(\.stringValue) ?? [],
                messageID: payload["messageId"]?.stringValue ?? ""
            )
        case "recordingStateChanged":
            event = .recordingStateChanged(payload)
        case "e2eeVerificationAvailable", "e2eeVerificationReady", "e2eeVerificationCompleted":
            event = .e2EEStateChanged(payload)
        case "participantKicked":
            event = .kick(payload["id"]?.stringValue ?? "")
        case "kicked":
            event = .selfKicked(
                actor: payload["actor"]?.stringValue,
                reason: payload["reason"]?.stringValue ?? "",
                replaced: payload["replaced"]?.boolValue ?? false
            )
        case "localMutedByFocus":
            event = .localMutedByFocus(
                mediaType: MediaType(rawValue: payload["mediaType"]?.stringValue ?? "") ?? .audio,
                isScreenShare: payload["desktop"]?.boolValue ?? false,
                actor: payload["actor"]?.stringValue
            )
        default:
            event = .raw(name: name, payload)
        }
        continuation?.yield(event)
    }

    private func defaultTrack(_ payload: JSONValue) -> TrackSnapshot {
        TrackSnapshot(
            id: payload["id"]?.stringValue ?? UUID().uuidString,
            mediaType: MediaType(rawValue: payload["mediaType"]?.stringValue ?? "") ?? .audio,
            isLocal: payload["isLocal"]?.boolValue ?? false,
            muted: payload["muted"]?.boolValue ?? false,
            videoType: VideoType(rawValue: payload["videoType"]?.stringValue ?? "") ?? .noVideo,
            deviceID: payload["deviceID"]?.stringValue,
            label: payload["label"]?.stringValue ?? ""
        )
    }
}

private extension JSONValue {
    func trackSnapshot() -> TrackSnapshot? {
        guard let id = self["id"]?.stringValue else { return nil }
        return TrackSnapshot(
            id: id,
            mediaType: MediaType(rawValue: self["mediaType"]?.stringValue ?? self["kind"]?.stringValue ?? "") ?? .audio,
            isLocal: self["isLocal"]?.boolValue ?? false,
            muted: self["muted"]?.boolValue ?? false,
            videoType: VideoType(rawValue: self["videoType"]?.stringValue ?? "") ?? .noVideo,
            deviceID: self["deviceID"]?.stringValue ?? self["deviceId"]?.stringValue,
            label: self["label"]?.stringValue ?? ""
        )
    }

    func trackSnapshots() -> [TrackSnapshot] {
        arrayValue.compactMap { entry in
            if let snapshot = entry.trackSnapshot() {
                return snapshot
            }
            return entry["track"]?.trackSnapshot()
        }
    }

    func participantSnapshot() -> ParticipantSnapshot? {
        guard let id = self["id"]?.stringValue else { return nil }
        return ParticipantSnapshot(
            id: id,
            displayName: self["displayName"]?.stringValue ?? "",
            role: ParticipantRole(rawValue: self["role"]?.stringValue ?? "") ?? .participant,
            isLocal: self["isLocal"]?.boolValue ?? false,
            raisedHand: self["raisedHand"]?.boolValue ?? false,
            tracks: self["tracks"]?.arrayValue.compactMap { $0.trackSnapshot() } ?? [],
            avatarURL: self["avatarURL"]?.stringValue,
            email: self["email"]?.stringValue,
            properties: self["properties"]?.objectValue ?? [:],
            jid: self["jid"]?.stringValue ?? "",
            connectionJID: self["connectionJID"]?.stringValue,
            status: self["status"]?.stringValue ?? "",
            botType: self["botType"]?.stringValue,
            statsID: self["statsID"]?.stringValue ?? "",
            isSilent: self["isSilent"]?.boolValue ?? false,
            isReplacing: self["isReplacing"]?.boolValue ?? false,
            isReplaced: self["isReplaced"]?.boolValue ?? false,
            isHidden: self["isHidden"]?.boolValue ?? false,
            isAudioMuted: self["isAudioMuted"]?.boolValue ?? false,
            isVideoMuted: self["isVideoMuted"]?.boolValue ?? false
        )
    }

    func speakerStats() -> SpeakerStats? {
        guard let id = self["participantId"]?.stringValue else { return nil }
        let landmarks = self["faceLandmarks"]?.arrayValue.compactMap { item -> SpeakerStats.FaceLandmark? in
            guard let expression = item["faceExpression"]?.stringValue else { return nil }
            return SpeakerStats.FaceLandmark(
                duration: item["duration"]?.doubleValue ?? 0,
                faceExpression: expression)
        } ?? []
        return SpeakerStats(
            participantID: id,
            displayName: self["displayName"]?.stringValue ?? "",
            isLocal: self["isLocal"]?.boolValue ?? false,
            isDominantSpeaker: self["isDominantSpeaker"]?.boolValue ?? false,
            totalDominantSpeakerTime: (self["totalDominantSpeakerTime"]?.doubleValue ?? 0) / 1000,
            hasLeft: self["hasLeft"]?.boolValue ?? false,
            faceLandmarks: landmarks
        )
    }

    func lobbyUser() -> LobbyUser? {
        guard let id = self["id"]?.stringValue else { return nil }
        return LobbyUser(
            id: id,
            displayName: self["displayName"]?.stringValue ?? "",
            email: self["email"]?.stringValue,
            avatarURL: self["avatarURL"]?.stringValue
        )
    }

    func moderationMediaType() -> AVModerationMediaType? {
        self.stringValue.flatMap(AVModerationMediaType.init(rawValue:))
    }

    /// Room list and capability flags. Rooms keep the component's order, so a moderator UI
    /// can render them as the server lists them.
    func breakoutRoomsState() -> BreakoutRoomsState {
        BreakoutRoomsState(
            isSupported: self["isSupported"]?.boolValue ?? false,
            canRename: self["canRename"]?.boolValue ?? false,
            isBreakoutRoom: self["isBreakoutRoom"]?.boolValue ?? false,
            mainRoomJID: self["mainRoomJID"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 },
            rooms: self["rooms"]?.arrayValue.compactMap { $0.breakoutRoom() } ?? [],
            roomCounter: Int(self["roomCounter"]?.doubleValue ?? 0)
        )
    }

    func breakoutRoom() -> BreakoutRoom? {
        guard let jid = self["jid"]?.stringValue, !jid.isEmpty else { return nil }
        return BreakoutRoom(
            id: self["id"]?.stringValue ?? "",
            jid: jid,
            name: self["name"]?.stringValue ?? "",
            isMainRoom: self["isMainRoom"]?.boolValue ?? false,
            participants: self["participants"]?.arrayValue.compactMap { $0.breakoutRoomParticipant() } ?? []
        )
    }

    func breakoutRoomParticipant() -> BreakoutRoomParticipant? {
        guard let jid = self["jid"]?.stringValue, !jid.isEmpty else { return nil }
        return BreakoutRoomParticipant(
            jid: jid,
            displayName: self["displayName"]?.stringValue ?? "",
            role: ParticipantRole(rawValue: self["role"]?.stringValue ?? "") ?? .participant
        )
    }
}

private extension ParticipantSnapshot {
    static func empty(_ id: String) -> ParticipantSnapshot {
        ParticipantSnapshot(id: id, displayName: "", role: .participant, isLocal: false, raisedHand: false, tracks: [])
    }
}
