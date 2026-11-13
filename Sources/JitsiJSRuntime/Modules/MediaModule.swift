import Foundation
import JitsiCore
import JitsiMedia

/// `media.*` and `pc.*`: the native half of the WebRTC facade in 30-webrtc.js.
///
/// Capture and peer connections are owned here; JS only ever handles opaque track ids
/// and SDP strings, which is what keeps lib-jitsi-meet's SDP munging valid against a
/// native stack.
///
/// `@unchecked Sendable`: every mutable table here is read and written on the JS context
/// queue only; libwebrtc callbacks hop onto that queue before touching module state.
final class MediaModule: NativeModule, @unchecked Sendable {
    let prefixes = ["media", "pc"]

    private weak var host: JSCEngineHost?
    private let backend: MediaBackend
    private let capabilities: MediaCapabilities

    private var tracks: [TrackID: TrackSnapshot] = [:]
    private var peers: [String: PeerConnectionHandle] = [:]
    private var streamCounter = 1
    /// `media.trackStop` is synchronous but the backend stop is not. A rejoin that skipped
    /// its backoff (network just came back) captures again in the same tick, and starting
    /// the camera before the previous session is released fails on iOS. Capture starts
    /// await this chain, so stop always lands first.
    private var pendingCaptureStop: Task<Void, Never>?

    init(host: JSCEngineHost, backend: MediaBackend, capabilities: MediaCapabilities) {
        self.host = host
        self.backend = backend
        self.capabilities = capabilities
    }

    // MARK: - Awaitable calls

    func call(_ method: String, _ args: JSONValue, _ reply: @escaping (Result<JSONValue, Error>) -> Void) {
        switch method {
        case "media.getUserMedia":
            getUserMedia(args, reply)
        case "media.getDisplayMedia":
            getDisplayMedia(reply)
        case "media.enumerateDevices":
            Task {
                do {
                    let devices = try await self.backend.enumerateDevices()
                    reply(.success(.array(devices.map(Self.deviceJSON))))
                } catch {
                    reply(.failure(error))
                }
            }
        case "media.applyConstraints":
            guard let id = args["trackId"]?.stringValue, let track = tracks[id], track.mediaType == .video else {
                return reply(.failure(JitsiError.noLocalTrack(.video)))
            }
            let constraints = Self.videoConstraints(args["constraints"] ?? .object([:]))
            Task {
                do {
                    let applied = try await self.backend.applyVideoConstraints(constraints, for: id)
                    reply(.success(Self.capabilitiesJSON(applied)))
                } catch {
                    reply(.failure(error))
                }
            }
        case "media.trackCapabilities":
            guard let id = args["trackId"]?.stringValue, let track = tracks[id], track.mediaType == .video else {
                return reply(.failure(JitsiError.noLocalTrack(.video)))
            }
            Task {
                do {
                    reply(.success(Self.capabilitiesJSON(try await self.backend.videoCapabilities(for: id))))
                } catch {
                    reply(.failure(error))
                }
            }
        case "pc.createOffer":
            guard let peer = peer(args["pcId"]) else { return reply(.failure(noPeer)) }
            Task {
                do {
                    reply(.success(try await peer.createOffer(simulcast: self.capabilities.supportsSimulcast)))
                } catch {
                    reply(.failure(error))
                }
            }
        case "pc.createAnswer":
            guard let peer = peer(args["pcId"]) else { return reply(.failure(noPeer)) }
            Task {
                do {
                    reply(.success(try await peer.createAnswer()))
                } catch {
                    reply(.failure(error))
                }
            }
        case "pc.setLocalDescription", "pc.setRemoteDescription":
            guard let peer = peer(args["pcId"]) else { return reply(.failure(noPeer)) }
            let type = SDPType(rawValue: args["type"]?.stringValue ?? "") ?? .offer
            let sdp = args["sdp"]?.stringValue ?? ""
            Task {
                do {
                    if method == "pc.setLocalDescription" {
                        try await peer.setLocalDescription(type: type, sdp: sdp)
                    } else {
                        try await peer.setRemoteDescription(type: type, sdp: sdp)
                    }
                    reply(.success(.bool(true)))
                } catch {
                    reply(.failure(error))
                }
            }
        case "pc.addIceCandidate":
            guard let peer = peer(args["pcId"]) else { return reply(.failure(noPeer)) }
            let candidate = args["candidate"] ?? .null
            Task {
                do {
                    try await peer.addIceCandidate(candidate)
                    reply(.success(.bool(true)))
                } catch {
                    reply(.failure(error))
                }
            }
        case "pc.setEncodingParameters":
            guard let peer = peer(args["pcId"]) else { return reply(.failure(noPeer)) }
            let encodings = args["encodings"]?.arrayValue ?? []
            let bitrate = encodings.first?["maxBitrate"]?.intValue.map { $0 / 1000 }
            let scalability = encodings.first?["scalabilityMode"]?.stringValue
            Task {
                do {
                    try await peer.applyEncodingParameters(maxBitrateKbps: bitrate, scalabilityMode: scalability)
                    reply(.success(.bool(true)))
                } catch {
                    reply(.failure(error))
                }
            }
        case "pc.getStats":
            guard let peer = peer(args["pcId"]) else { return reply(.failure(noPeer)) }
            Task {
                do {
                    reply(.success(try await peer.statistics()))
                } catch {
                    reply(.failure(error))
                }
            }
        default:
            reply(.failure(JitsiError.unsupported(method)))
        }
    }

    // MARK: - Synchronous calls

    /// `pc.create` answers in the same tick: the JS constructor must have a peer id
    /// before it returns, otherwise `addEventListener` ordering breaks.
    func syncResult(_ method: String, _ args: JSONValue) -> JSONValue? {
        if method == "pc.addTrack" {
            // addTrack stays synchronous: lib-jitsi-meet expects the sender before it
            // continues building the offer, and the sender id is what later lets
            // `sender.replaceTrack()` find this transceiver again.
            guard let peer = peer(args["pcId"]), let trackID = args["trackId"]?.stringValue else {
                return nil
            }
            let streamID = args["streamIds"]?.arrayValue.first?.stringValue ?? "native-stream"
            let senderID = peer.addTrack(trackID, streamID: streamID, capture: tracks[trackID] != nil)
            return .object(["senderId": senderID.map(JSONValue.string) ?? .null])
        }
        guard method == "pc.create" else { return nil }
        // The backend hands us the handle and its events in the same call, so the id is
        // published through a box that only the JS queue ever touches.
        let idBox = PeerIDBox()
        let created = backend.makePeerConnection(
            Self.configuration(args["configuration"] ?? .object([:]))
        ) { [weak self, idBox] event in
            self?.host?.queue.async { [weak self] in
                self?.emit(event, peerID: idBox.value)
            }
        }
        guard let created else { return nil }
        idBox.value = created.id
        peers[created.id] = created
        return .object(["pcId": .string(created.id)])
    }

    func sync(_ method: String, _ args: JSONValue) {
        switch method {
        case "media.trackStop":
            if let id = args["trackId"]?.stringValue {
                tracks[id] = nil
                stopCapture([id])
            }
        case "media.trackEnabled":
            // lib-jitsi-meet muted a local track in JS; only capture tracks are known here,
            // so remote track ids fall through instead of erroring.
            guard let id = args["trackId"]?.stringValue, tracks[id] != nil else { return }
            let enabled = args["enabled"]?.boolValue ?? true
            if var snapshot = tracks[id] {
                snapshot.muted = !enabled
                tracks[id] = snapshot
            }
            Task { try? await self.backend.setTrackMuted(id, muted: !enabled) }
        case "pc.addTrack":
            guard let peer = peer(args["pcId"]), let trackID = args["trackId"]?.stringValue else { return }
            let streamID = args["streamIds"]?.arrayValue.first?.stringValue ?? "native-stream"
            _ = peer.addTrack(trackID, streamID: streamID, capture: tracks[trackID] != nil)
        case "pc.removeTrack":
            if let peer = peer(args["pcId"]), let trackID = args["trackId"]?.stringValue {
                peer.removeTrack(trackID)
            }
        case "pc.replaceTrack":
            // lib-jitsi-meet swaps the track on an existing sender after the session is up
            // (every `conference.addTrack`, screen share, and P2P source change takes this
            // path), so ignoring it left the native sender permanently empty.
            guard let peer = peer(args["pcId"]) else { return }
            peer.replaceTrack(
                senderID: args["senderId"]?.stringValue,
                oldTrackID: args["oldTrackId"]?.stringValue,
                trackID: args["trackId"]?.stringValue,
                kind: args["kind"]?.stringValue)
        case "pc.createDataChannel":
            let label = args["label"]?.stringValue ?? "MessageChannel"
            peer(args["pcId"])?.openDataChannel(label: label, kind: label == "MessageChannel" ? .bridge : .colibri)
        case "pc.sendData":
            if let peer = peer(args["pcId"]), let text = args["text"]?.stringValue {
                peer.send(text, onChannel: args["label"]?.stringValue ?? "MessageChannel")
            }
        case "pc.close":
            guard let id = args["pcId"]?.stringValue, let peer = peers[id] else { return }
            peer.close()
            peers[id] = nil
        case "pc.setConfiguration", "pc.closeDataChannel":
            break
        default:
            break
        }
    }

    func shutdown() {
        for peer in peers.values {
            peer.close()
        }
        peers.removeAll()
        let live = Array(tracks.keys)
        tracks.removeAll()
        if !live.isEmpty {
            stopCapture(live)
        }
    }

    /// Serializes backend stops. Only the JS queue mutates `pendingCaptureStop`.
    private func stopCapture(_ ids: [String]) {
        let previous = pendingCaptureStop
        pendingCaptureStop = Task { [backend] in
            _ = await previous?.value
            await backend.stopCapture(ids)
        }
    }

    // MARK: - Capture

    /// lib-jitsi-meet's React-Native desktop path calls `getDisplayMedia({video:true})`.
    /// The frames come from the ReplayKit broadcast extension over the App Group socket, so
    /// the track exists as soon as the socket is listening; the first frames arrive when the
    /// user starts the system broadcast.
    private func getDisplayMedia(_ reply: @escaping (Result<JSONValue, Error>) -> Void) {
        Task {
            do {
                let snapshot = try await backend.startScreenShare()
                tracks[snapshot.id] = snapshot
                let streamID = "native-screen-\(streamCounter)"
                streamCounter += 1
                reply(.success(.object([
                    "streamId": .string(streamID),
                    "tracks": .array([Self.trackJSON(snapshot)])
                ])))
            } catch {
                reply(.failure(error))
            }
        }
    }

    private func getUserMedia(_ args: JSONValue, _ reply: @escaping (Result<JSONValue, Error>) -> Void) {
        let constraints = args["constraints"] ?? .object([:])
        var requested: [MediaType] = []
        var deviceIDs: [String: String] = [:]

        if let audio = constraints["audio"], Self.requests(audio) {
            requested.append(.audio)
            if let id = audio["deviceId"]?.stringValue {
                deviceIDs["audio"] = id
            }
        }
        if let video = constraints["video"], Self.requests(video) {
            requested.append(.video)
            if let id = video["deviceId"]?.stringValue {
                deviceIDs["video"] = id
            }
        }
        guard !requested.isEmpty else {
            reply(.failure(JitsiError.unsupported("getUserMedia requested no media type")))
            return
        }

        // Released synchronously for the caller, but the backend stop is async; a rejoin
        // that starts right away has to wait for it or the camera is still busy.
        let pendingStop = pendingCaptureStop
        Task {
            await pendingStop?.value
            let granted = await backend.requestAccess(for: requested)
            if let denied = requested.first(where: { granted[$0] == false }) {
                reply(.failure(JitsiError.captureDenied(denied)))
                return
            }
            do {
                let created = try await backend.startCapture(requested, deviceIDs: deviceIDs)
                for snapshot in created {
                    tracks[snapshot.id] = snapshot
                }
                let streamID = "native-stream-\(streamCounter)"
                streamCounter += 1
                reply(.success(.object([
                    "streamId": .string(streamID),
                    "tracks": .array(created.map(Self.trackJSON))
                ])))
            } catch {
                reply(.failure(error))
            }
        }
    }

    /// `getUserMedia` turns a medium off with `false`/`null`; only a truthy value asks for the
    /// device. lib-jitsi-meet sends `{audio: true, video: false}` for audio-only capture.
    private static func requests(_ value: JSONValue) -> Bool {
        switch value {
        case .null, .bool(false): return false
        default: return true
        }
    }

    // MARK: - Conversion

    static func trackJSON(_ snapshot: TrackSnapshot) -> JSONValue {
        .object([
            "id": .string(snapshot.id),
            "kind": .string(snapshot.mediaType == .audio ? "audio" : "video"),
            "label": .string(snapshot.label),
            "deviceId": snapshot.deviceID.map(JSONValue.string) ?? .null,
            "muted": .bool(snapshot.muted),
            "enabled": .bool(!snapshot.muted)
        ])
    }

    /// MediaTrackConstraints puts the number under `ideal`/`exact`; plain numbers are accepted
    /// too, because the Swift facade and direct JS callers both use this entry point.
    static func videoConstraints(_ raw: JSONValue) -> VideoConstraints {
        VideoConstraints(
            width: intConstraint(raw["width"]),
            height: intConstraint(raw["height"]),
            frameRate: intConstraint(raw["frameRate"]))
    }

    private static func intConstraint(_ value: JSONValue?) -> Int? {
        guard let value, value.isPresent else { return nil }
        if let direct = value.intValue {
            return direct
        }
        for key in ["ideal", "exact", "max"] {
            if let number = value[key]?.intValue {
                return number
            }
        }
        return nil
    }

    static func capabilitiesJSON(_ capabilities: VideoTrackCapabilities) -> JSONValue {
        .object([
            "deviceId": capabilities.deviceID.map(JSONValue.string) ?? .null,
            "activeWidth": capabilities.activeWidth.map { .number(Double($0)) } ?? .null,
            "activeHeight": capabilities.activeHeight.map { .number(Double($0)) } ?? .null,
            "activeFrameRate": capabilities.activeFrameRate.map(JSONValue.number) ?? .null,
            "formats": .array(capabilities.formats.map { format in
                .object([
                    "width": .number(Double(format.width)),
                    "height": .number(Double(format.height)),
                    "minFrameRate": .number(format.minFrameRate),
                    "maxFrameRate": .number(format.maxFrameRate)
                ])
            })
        ])
    }

    static func deviceJSON(_ device: DeviceDescriptor) -> JSONValue {
        .object([
            "deviceId": .string(device.id),
            "kind": .string(device.kind == .audio ? "audioinput" : "videoinput"),
            "label": .string(device.label),
            "groupId": .string(device.id),
            "facing": .string(device.facing.rawValue)
        ])
    }

    static func configuration(_ raw: JSONValue) -> PeerConnectionConfig {
        var config = PeerConnectionConfig()
        let servers = raw["iceServers"]?.arrayValue ?? []
        // lib-jitsi-meet uses both shapes: `urls` is an array on some paths and a single
        // string on others (P2P and Jicofo's TURN list). A server with no usable URL must be
        // dropped — libwebrtc rejects the whole configuration with "Empty uri".
        config.iceServers = servers.compactMap { server in
            let urls = server["urls"]
            let list: [String]
            if let array = urls?.arrayValue, !array.isEmpty {
                list = array.compactMap(\.stringValue)
            } else if let single = urls?.stringValue {
                list = [single]
            } else {
                list = []
            }
            let usable = list.filter { !$0.isEmpty }
            guard !usable.isEmpty else { return nil }
            return PeerConnectionConfig.ICEServer(
                urls: usable,
                username: server["username"]?.stringValue,
                credential: server["credential"]?.stringValue
            )
        }
        config.enableSimulcast = raw["enableSimulcast"]?.boolValue ?? config.enableSimulcast
        return config
    }

    private var noPeer: JitsiError {
        .unsupported("peer connection is gone")
    }

    private func peer(_ id: JSONValue?) -> PeerConnectionHandle? {
        guard let key = id?.stringValue else { return nil }
        return peers[key]
    }

    /// Routes a backend event onto the `pc:<id>` channel the JS facade listens to.
    private func emit(_ event: PeerEvent, peerID: String?) {
        guard let peerID else { return }
        host?.emit(channel: "pc:\(peerID)", "event", event.payload)
    }
}

/// Mutable holder written on the JS queue right after the handle is created.
/// Queue-confined: only the JS queue ever reads `value`, and it is written before the
/// peer connection can emit.
private final class PeerIDBox: @unchecked Sendable {
    var value: String?
}

private extension PeerEvent {
    var payload: JSONValue {
        switch self {
        case .signalingState(let state):
            return .object(["type": .string("signalingState"), "state": .string(state)])
        case .iceConnectionState(let state):
            return .object(["type": .string("iceConnectionState"), "state": .string(state)])
        case .iceGatheringState(let state):
            return .object(["type": .string("iceGatheringState"), "state": .string(state)])
        case .connectionState(let state):
            return .object(["type": .string("connectionState"), "state": .string(state)])
        case .iceCandidate(let endpoint, let candidate):
            var payload: [String: JSONValue] = ["type": .string("icecandidate"), "candidate": candidate]
            if let endpoint {
                payload["endpoint"] = .string(endpoint)
            }
            return .object(payload)
        case .localDescription(let type, let sdp):
            return .object([
                "type": .string("localDescription"),
                "state": .string(type.rawValue),
                "sdp": .string(sdp)
            ])
        case .dataChannelOpen(let label):
            return .object([
                "type": .string("channelState"),
                "label": .string(label),
                "state": .string("open")
            ])
        case .dataChannelMessage(let label, let text):
            return .object([
                "type": .string("channelMessage"),
                "label": .string(label),
                "text": text.map(JSONValue.string) ?? .null
            ])
        case .incomingTrack(let snapshot, let streamID, let mid):
            return .object([
                "type": .string("track"),
                "track": MediaModule.trackJSON(snapshot),
                "streamId": .string(streamID),
                "mid": mid.map(JSONValue.string) ?? .null
            ])
        case .trackMuted(let trackID, let muted):
            return .object([
                "type": .string("trackMuted"),
                "id": .string(trackID),
                "muted": .bool(muted)
            ])
        case .failed(let code, let message):
            return .object([
                "type": .string("failed"),
                "code": .number(Double(code)),
                "message": .string(message)
            ])
        }
    }
}
