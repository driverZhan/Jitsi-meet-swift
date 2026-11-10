import CoreVideo
import Foundation
import JitsiCore

public struct PeerConnectionConfig: Sendable {
    public struct ICEServer: Sendable {
        public var urls: [String]
        public var username: String?
        public var credential: String?

        public init(urls: [String], username: String? = nil, credential: String? = nil) {
            self.urls = urls
            self.username = username
            self.credential = credential
        }
    }

    public var iceServers: [ICEServer]
    public var enableSimulcast: Bool
    public var scalabilityMode: String?
    public var initialBitrateKbps: Int?

    public init(
        iceServers: [ICEServer] = [],
        enableSimulcast: Bool = true,
        scalabilityMode: String? = nil,
        initialBitrateKbps: Int? = nil
    ) {
        self.iceServers = iceServers
        self.enableSimulcast = enableSimulcast
        self.scalabilityMode = scalabilityMode
        self.initialBitrateKbps = initialBitrateKbps
    }
}

public enum SDPType: String, Sendable {
    case offer
    case answer
    case pranswer = "pranswer"
}

/// Everything the JS `RTCPeerConnection` facade needs to forward down to libwebrtc.
/// SDP travels as raw strings, which is what makes lib-jitsi-meet's SDP munging portable.
public enum PeerEvent: Sendable {
    case signalingState(String)
    case iceConnectionState(String)
    case iceGatheringState(String)
    case connectionState(String)
    case iceCandidate(endpoint: String?, JSONValue)
    case localDescription(SDPType, sdp: String)
    case dataChannelOpen(label: String)
    case dataChannelMessage(label: String, text: String?)
    /// `streamID` is the MSID stream id, not the track id: lib-jitsi-meet matches a
    /// remote track to its SDP m-line by stream id, and it deliberately ignores the
    /// JVB's `mixedmslabel` streams. `mid`, when known, is the exact m-line.
    case incomingTrack(TrackSnapshot, streamID: String, mid: String?)
    case trackMuted(TrackID, Bool)
    case failed(code: Int, message: String)
}

public enum DataChannelKind: String, Sendable {
    /// JVB `MessageChannel` (reliable, ordered, string frames).
    case bridge
    /// JVB `openBridgeChannel` colibri-ws over WebSocket, or binary bridges.
    case colibri
}

public protocol PeerConnectionHandle: AnyObject {
    var id: String { get }

    /// Track and channel setup is synchronous in the browser API and in libwebrtc, so it
    /// must stay synchronous here too; an async hop would let `setLocalDescription`
    /// race ahead of the tracks lib-jitsi-meet just added.
    /// Returns the native sender id so the JS shim can address this sender when
    /// lib-jitsi-meet replaces the track instead of re-adding it.
    @discardableResult
    func addTrack(_ trackID: TrackID, streamID: String, capture: Bool) -> String?
    func removeTrack(_ trackID: TrackID)
    /// W3C `RTCRtpSender.replaceTrack`. `senderID` is nil for senders the shim materialised
    /// from a remote m-line; `trackID` is nil when the track is being detached.
    func replaceTrack(senderID: String?, oldTrackID: TrackID?, trackID: TrackID?, kind: String?)
    func openDataChannel(label: String, kind: DataChannelKind)
    func send(_ text: String, onChannel label: String)
    func close()

    func setLocalDescription(type: SDPType, sdp: String) async throws
    func setRemoteDescription(type: SDPType, sdp: String) async throws
    func addIceCandidate(_ candidate: JSONValue) async throws

    /// Returns `{ type, sdp }`; SDP must stay a raw string so the JS layer can munge it.
    func createOffer(simulcast: Bool) async throws -> JSONValue
    func createAnswer() async throws -> JSONValue

    func applyEncodingParameters(maxBitrateKbps: Int?, scalabilityMode: String?) async throws
    func statistics() async throws -> JSONValue
}

/// The host of the WebRTC stack. libwebrtc is one implementation; a future native
/// implementation can replace it without touching `JitsiJSRuntime`.
public protocol MediaBackend: AnyObject {
    var capabilities: MediaCapabilities { get }

    func prepare() async throws
    func shutdown() async

    /// Activates the platform audio session and lets the media engine start its input and
    /// playout units. Must run before local audio capture and before remote audio is played,
    /// and be balanced with `deactivateAudioSession()`. Voice processing cannot run on the
    /// default ambient session, so skipping this yields RTP that carries silence in both
    /// directions.
    func activateAudioSession(preferSpeaker: Bool) async throws
    func deactivateAudioSession() async

    func enumerateDevices() async throws -> [DeviceDescriptor]
    func requestAccess(for mediaTypes: [MediaType]) async -> [MediaType: Bool]

    /// Capture is owned natively; the JS layer only ever sees opaque track IDs.
    func startCapture(_ mediaTypes: [MediaType], deviceIDs: [String: String]) async throws -> [TrackSnapshot]
    func stopCapture(_ trackIDs: [TrackID]) async
    /// Front/back switch on the live capture session. The track id is deliberately
    /// unchanged: frames keep flowing to the same sender, so no renegotiation is needed.
    func switchCamera() async throws -> String
    /// Formats the camera feeding `trackID` supports, and the ones it is producing now.
    func videoCapabilities(for trackID: TrackID) async throws -> VideoTrackCapabilities
    /// Reconfigures the running camera. The track and its sender stay allocated; only the
    /// capture format changes, so no SDP negotiation is triggered.
    func applyVideoConstraints(_ constraints: VideoConstraints, for trackID: TrackID) async throws
        -> VideoTrackCapabilities
    func setTrackMuted(_ trackID: TrackID, muted: Bool) async throws
    func frameStream(for trackID: TrackID) -> AsyncStream<VideoPixelFrame>

    /// Creates a synthetic desktop track fed by the ReplayKit broadcast extension. The
    /// track exists immediately, but frames only start once the user starts the system
    /// broadcast; until then the receiver simply has no connection.
    func startScreenShare() async throws -> TrackSnapshot
    func stopScreenShare() async

    /// Returns nil when the platform refuses the configuration; the JS facade turns that into a
    /// regular `RTCPeerConnection` error instead of tearing down the host process.
    func makePeerConnection(_ config: PeerConnectionConfig, onEvent: @escaping @Sendable (PeerEvent) -> Void) -> PeerConnectionHandle?
}

public extension MediaBackend {
    func startScreenShare() async throws -> TrackSnapshot {
        throw JitsiError.unsupported("screen sharing")
    }

    func stopScreenShare() async {}

    /// Backends without an audio device module (tests, placeholders) have nothing to activate.
    func activateAudioSession(preferSpeaker: Bool) async throws {}
    func deactivateAudioSession() async {}

    /// Synthetic and placeholder tracks have no camera formats to inspect or change.
    func videoCapabilities(for _: TrackID) async throws -> VideoTrackCapabilities {
        throw JitsiError.unsupported("videoCapabilities")
    }

    func applyVideoConstraints(_: VideoConstraints, for _: TrackID) async throws -> VideoTrackCapabilities {
        throw JitsiError.unsupported("applyVideoConstraints")
    }
}

public enum MediaBackendFactory {
    /// Returns the linked backend. libwebrtc is vendored, so this is `WebRTCBackend`; an
    /// integrator who drops the `WebRTC` binary target gets the placeholder below, which fails
    /// loudly instead of pretending a conference can be started.
    public static func makeDefault(capabilities: MediaCapabilities) -> MediaBackend {
        #if canImport(WebRTC)
        return WebRTCBackend(capabilities: capabilities)
        #else
        return UnavailableMediaBackend(capabilities: capabilities)
        #endif
    }
}

/// Placeholder that fails loudly at runtime instead of silently pretending to work.
public final class UnavailableMediaBackend: MediaBackend {
    public let capabilities: MediaCapabilities

    public init(capabilities: MediaCapabilities) {
        self.capabilities = capabilities
    }

    public func prepare() async throws { throw JitsiError.mediaBackendNotLinked }
    public func shutdown() async {}

    public func enumerateDevices() async throws -> [DeviceDescriptor] { throw JitsiError.mediaBackendNotLinked }

    public func requestAccess(for mediaTypes: [MediaType]) async -> [MediaType: Bool] {
        mediaTypes.reduce(into: [MediaType: Bool]()) { partial, mediaType in partial[mediaType] = false }
    }

    public func startCapture(_: [MediaType], deviceIDs _: [String: String]) async throws -> [TrackSnapshot] {
        throw JitsiError.mediaBackendNotLinked
    }

    public func stopCapture(_: [TrackID]) async {}
    public func switchCamera() async throws -> String { throw JitsiError.mediaBackendNotLinked }
    public func setTrackMuted(_: TrackID, muted _: Bool) async throws { throw JitsiError.mediaBackendNotLinked }
    public func startScreenShare() async throws -> TrackSnapshot { throw JitsiError.mediaBackendNotLinked }

    public func frameStream(for _: TrackID) -> AsyncStream<VideoPixelFrame> {
        AsyncStream { $0.finish() }
    }

    public func makePeerConnection(
        _: PeerConnectionConfig,
        onEvent _: @escaping @Sendable (PeerEvent) -> Void
    ) -> PeerConnectionHandle? {
        ClosedPeerConnection()
    }
}

private final class ClosedPeerConnection: PeerConnectionHandle {
    let id = UUID().uuidString

    @discardableResult
    func addTrack(_: TrackID, streamID _: String, capture _: Bool) -> String? {
        NSLog("[jitsi-media] link WebRTC.framework to add tracks")
        return nil
    }

    func removeTrack(_: TrackID) {}
    func replaceTrack(senderID _: String?, oldTrackID _: TrackID?, trackID _: TrackID?, kind _: String?) {}
    func openDataChannel(label _: String, kind _: DataChannelKind) {}
    func send(_: String, onChannel _: String) {}
    func close() {}

    private func unavailable() throws {
        throw JitsiError.mediaBackendNotLinked
    }

    func setLocalDescription(type _: SDPType, sdp _: String) async throws { try unavailable() }
    func setRemoteDescription(type _: SDPType, sdp _: String) async throws { try unavailable() }
    func addIceCandidate(_: JSONValue) async throws { try unavailable() }
    func createOffer(simulcast _: Bool) async throws -> JSONValue {
        try unavailable()
        return .object([:])
    }

    func createAnswer() async throws -> JSONValue {
        try unavailable()
        return .object([:])
    }

    func applyEncodingParameters(maxBitrateKbps _: Int?, scalabilityMode _: String?) async throws { try unavailable() }

    func statistics() async throws -> JSONValue {
        try unavailable()
        return .object([:])
    }
}
