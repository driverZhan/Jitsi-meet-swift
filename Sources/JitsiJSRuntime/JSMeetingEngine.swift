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

    public let events: AsyncStream<MeetingEvent>
    private var continuation: AsyncStream<MeetingEvent>.Continuation?

    /// Track ids created natively, mirrored so mute can be resolved per media type.
    private var capturedTracks: [MediaType: TrackID] = [:]

    public init(
        backend: MediaBackend,
        hostName: String,
        logLevel: String = "info",
        debugSignaling: Bool = false
    ) {
        self.backend = backend
        self.logLevel = logLevel
        self.debugSignaling = debugSignaling
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
    }

    public func dispose() async {
        host.setEventHandler(nil)
        _ = try? await host.invoke("lib.dispose", args: .object([:]))
        host.stop()
        await backend.shutdown()
        continuation?.finish()
    }

    // MARK: - Connection

    public func connect(_ options: ConnectionOptions) async throws {
        var hosts: [String: JSONValue] = [
            "domain": .string(options.hosts.domain),
            "muc": .string(options.hosts.muc)
        ]
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
        // The JS side settles this promise on CONNECTION_ESTABLISHED, so returning here means
        // the XMPP socket is usable; the status event itself comes from `wireConnection`.
        _ = try await host.invoke("connection.connect", args: .object(args))
    }

    public func disconnect() async {
        _ = try? await host.invoke("connection.disconnect", args: .object([:]))
    }

    // MARK: - Conference

    public func joinConference(_ options: ConferenceOptions) async throws {
        // initJitsiConference(name, options) maps `options` straight onto the conference
        // config, so configOverwrite is merged rather than nested. displayName travels as a
        // separate call; lib-jitsi-meet has no email/avatar presence API (the browser app
        // adds those extensions itself), so they stay out of the payload.
        var config = options.configOverwrite
        config["startAudioOnly"] = .bool(false)
        _ = try await host.invoke("conference.join", args: .object([
            "name": .string(options.name),
            "options": .object(options.connectionOptions.objectValue),
            "configOverwrite": .object(config)
        ]))
        try await setDisplayName(options.displayName)
    }

    public func leaveConference() async {
        _ = try? await host.invoke("conference.leave", args: .object([:]))
    }

    // MARK: - Media

    public func openCapture(_ mediaTypes: [MediaType], deviceIDs: [String: String]) async throws -> [TrackSnapshot] {
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

    public func setVideoQuality(_ height: Int) async throws {
        _ = try await host.invoke("conference.setLocalVideoQuality", args: .object(["height": .number(Double(height))]))
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

    public func setDisplayName(_ name: String) async throws {
        _ = try await host.invoke("conference.setDisplayName", args: .object(["name": .string(name)]))
    }

    public func raiseHand(_ raised: Bool) async throws {
        // Hand-raising is a jitsi-meet app feature, not lib-jitsi-meet: the app writes a
        // `<raise-hand>` presence extension through ChatRoom.addOrReplaceInPresence. Adding it
        // means extending the facade with a presence-editing call, not a Swift-side shim.
        throw JitsiError.unsupported("raiseHand: requires a presence-extension facade call (lib-jitsi-meet has no raiseHand API)")
    }

    public func kick(_ participantID: ParticipantID) async throws {
        _ = try await host.invoke("conference.kick", args: .object(["participantId": .string(participantID)]))
    }

    public func muteRemote(_ participantID: ParticipantID, mediaType: MediaType, mute: Bool) async throws {
        _ = try await host.invoke("conference.muteRemote", args: .object([
            "participantId": .string(participantID),
            "mediaType": .string(mediaType.rawValue),
            "mute": .bool(mute)
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
        case "conferenceJoined":
            event = .conferenceJoined(payload["id"]?.stringValue ?? "")
        case "conferenceLeft":
            event = .conferenceLeft(reason: payload["id"]?.stringValue)
        case "conferenceFailed":
            event = .conferenceFailed(.remote(payload["error"]?.stringValue ?? "conference failed"))
        case "participantJoined":
            event = .participantJoined(payload.participantSnapshot() ?? .empty(payload["id"]?.stringValue ?? ""))
        case "participantLeft":
            event = .participantLeft(payload.participantSnapshot() ?? .empty(payload["id"]?.stringValue ?? ""))
        case "participantDisplayNameChanged":
            event = .participantDisplayNameChanged(
                payload["id"]?.stringValue ?? "",
                payload["name"]?.stringValue ?? ""
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
        case "recordingStateChanged":
            event = .recordingStateChanged(payload)
        case "e2eeVerificationAvailable", "e2eeVerificationReady", "e2eeVerificationCompleted":
            event = .e2EEStateChanged(payload)
        case "participantKicked":
            event = .kick(payload["id"]?.stringValue ?? "")
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
            tracks: self["tracks"]?.arrayValue.compactMap { $0.trackSnapshot() } ?? []
        )
    }
}

private extension ParticipantSnapshot {
    static func empty(_ id: String) -> ParticipantSnapshot {
        ParticipantSnapshot(id: id, displayName: "", role: .participant, isLocal: false, raisedHand: false, tracks: [])
    }
}
