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

    public init(
        region: Region = .international,
        logLevel: String = "info",
        capabilities: MediaCapabilities = .default,
        e2eeEnabledByDefault: Bool = false,
        debugSignaling: Bool = false
    ) {
        self.region = region
        self.logLevel = logLevel
        self.capabilities = capabilities
        self.e2eeEnabledByDefault = e2eeEnabledByDefault
        self.debugSignaling = debugSignaling
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
}
