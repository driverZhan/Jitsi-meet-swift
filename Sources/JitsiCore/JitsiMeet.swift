import Foundation

public struct SDKConfig: Sendable {
    /// Region selector kept for configuration compatibility. Incoming-call presentation is
    /// identical in every region (notification + in-app overlay); see
    /// `JitsiCall.RegionPolicy`.
    public enum Region: String, Sendable {
        case chinaMainland
        case international
    }

    public var region: Region
    public var logLevel: String
    public var capabilities: MediaCapabilities
    public var e2eeEnabledByDefault: Bool
    /// Traces raw transport frames plus every parsed XMPP stanza and runs lib-jitsi-meet
    /// at DEBUG level. Logs can contain the JWT and SASL payloads, so keep it off in
    /// release builds.
    public var debugSignaling: Bool
    /// Injects `VoiceProcessingAudioDevice` in place of libwebrtc's built-in audio device
    /// module. Stage-0 probe for the local recording audio path; see README §12.5. Off by
    /// default, and the engine has to be installed again (`shutdown()` + `bootstrap`) for a
    /// change to take effect.
    public var useCustomAudioDevice: Bool
    /// When true a remote participant's screen share replaces their camera tile, so each
    /// participant still owns exactly one tile. Off by default: the share gets a tile of its
    /// own named "<name> 的屏幕", and the camera stays visible next to it.
    public var mergesRemoteScreenShareWithCamera: Bool

    public init(
        region: Region = .international,
        logLevel: String = "info",
        capabilities: MediaCapabilities = .default,
        e2eeEnabledByDefault: Bool = false,
        debugSignaling: Bool = false,
        useCustomAudioDevice: Bool = false,
        mergesRemoteScreenShareWithCamera: Bool = false
    ) {
        self.region = region
        self.logLevel = logLevel
        self.capabilities = capabilities
        self.e2eeEnabledByDefault = e2eeEnabledByDefault
        self.debugSignaling = debugSignaling
        self.useCustomAudioDevice = useCustomAudioDevice
        self.mergesRemoteScreenShareWithCamera = mergesRemoteScreenShareWithCamera
    }
}

/// Process-wide entry point. Main-actor confined so the façades, the UI store and the call
/// center can read `engine` without each of them re-establishing isolation.
@MainActor
public final class JitsiMeet {
    public static let shared = JitsiMeet()

    public private(set) var config = SDKConfig()
    public let events = EventHub()

    /// Set by the umbrella target once the JS runtime and media backend exist.
    public internal(set) weak var engine: MeetingEngine?
    public private(set) var connection: JitsiConnection?

    private init() {}

    public func attach(_ engine: MeetingEngine) {
        self.engine = engine
    }

    public func configure(_ config: SDKConfig) {
        self.config = config
    }

    public func createConnection(_ options: ConnectionOptions) throws -> JitsiConnection {
        guard engine != nil else { throw JitsiError.engineNotInstalled }
        let connection = JitsiConnection(options: options)
        self.connection = connection
        return connection
    }

    /// Runs lib-jitsi-meet's TURN/data-channel probe without joining a room. Pass the same
    /// TURN servers the deployment uses; without a relay candidate `mediaConnectivity`
    /// stays false even when the network is healthy.
    public func runPreCallTest(_ iceServers: [PreCallTestServer]) async throws -> PreCallTestResult {
        guard let engine else { throw JitsiError.engineNotInstalled }
        return try await engine.runPreCallTest(iceServers)
    }
}
