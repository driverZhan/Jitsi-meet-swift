import CoreVideo
import Foundation

/// Clockwise rotation the display has to apply to a frame to make it upright.
public enum VideoRotation: Int, Sendable {
    case none = 0
    case clockwise = 90
    case upsideDown = 180
    case counterClockwise = 270
}

/// A decoded/encoded video frame handed from the media backend to the renderer.
/// Declared in the core layer so the public API can expose frame streams without
/// depending on the media module.
public struct VideoPixelFrame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    /// Presentation time in the RTP clock, microseconds.
    public let timestampUs: Int64
    public let rotation: VideoRotation

    public init(pixelBuffer: CVPixelBuffer, timestampUs: Int64, rotation: VideoRotation = .none) {
        self.pixelBuffer = pixelBuffer
        self.timestampUs = timestampUs
        self.rotation = rotation
    }
}

public typealias TrackID = String
public typealias ParticipantID = String
public typealias ConferenceName = String

public enum MediaType: String, Sendable, CaseIterable {
    case audio
    case video
}

public enum VideoType: String, Sendable {
    case camera
    case desktop
    case noVideo = ""
}

public enum ConnectionStatus: String, Sendable {
    case idle
    case connecting
    case connected
    case disconnected
    case error
}

public enum ParticipantRole: String, Sendable {
    case owner
    case moderator
    case participant
    case visitor
    case none
}

/// Codec support reported to the JS layer; must mirror the linked libwebrtc build.
public struct MediaCapabilities: Sendable {
    public var videoCodecs: [String]
    public var audioCodecs: [String]
    public var supportsSimulcast: Bool
    public var supportsDataChannel: Bool

    public init(
        videoCodecs: [String] = ["vp8", "vp9", "h264"],
        audioCodecs: [String] = ["opus"],
        supportsSimulcast: Bool = true,
        supportsDataChannel: Bool = true
    ) {
        self.videoCodecs = videoCodecs
        self.audioCodecs = audioCodecs
        self.supportsSimulcast = supportsSimulcast
        self.supportsDataChannel = supportsDataChannel
    }

    public static let `default` = MediaCapabilities()
}

public struct DeviceDescriptor: Sendable, Equatable {
    public var id: String
    public var kind: MediaType
    public var label: String
    public var facing: CameraFacing

    public enum CameraFacing: String, Sendable {
        case unspecified
        case user
        case environment
    }

    public init(id: String, kind: MediaType, label: String, facing: CameraFacing = .unspecified) {
        self.id = id
        self.kind = kind
        self.label = label
        self.facing = facing
    }
}

public struct TrackSnapshot: Sendable, Equatable {
    public var id: TrackID
    public var mediaType: MediaType
    public var isLocal: Bool
    public var muted: Bool
    public var videoType: VideoType
    public var deviceID: String?
    public var label: String

    public init(
        id: TrackID,
        mediaType: MediaType,
        isLocal: Bool,
        muted: Bool = false,
        videoType: VideoType = .noVideo,
        deviceID: String? = nil,
        label: String = ""
    ) {
        self.id = id
        self.mediaType = mediaType
        self.isLocal = isLocal
        self.muted = muted
        self.videoType = videoType
        self.deviceID = deviceID
        self.label = label
    }
}

public struct ParticipantSnapshot: Sendable, Equatable {
    public var id: ParticipantID
    public var displayName: String
    public var role: ParticipantRole
    public var isLocal: Bool
    public var raisedHand: Bool
    public var tracks: [TrackSnapshot]
    /// Published with the `avatar-url` presence command. Nil when the participant has not
    /// shared one; jitsi-meet clients that log in with a JWT take the avatar from the token.
    public var avatarURL: String?
    /// Published with the `email` presence command.
    public var email: String?

    public init(
        id: ParticipantID,
        displayName: String,
        role: ParticipantRole = .participant,
        isLocal: Bool = false,
        raisedHand: Bool = false,
        tracks: [TrackSnapshot] = [],
        avatarURL: String? = nil,
        email: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.role = role
        self.isLocal = isLocal
        self.raisedHand = raisedHand
        self.tracks = tracks
        self.avatarURL = avatarURL
        self.email = email
    }
}

public struct RecordingOptions: Sendable {
    public enum Mode: String, Sendable {
        case stream
        case file
    }

    public var mode: Mode
    public var youTubeStreamKey: String?

    public init(mode: Mode, youTubeStreamKey: String? = nil) {
        self.mode = mode
        self.youTubeStreamKey = youTubeStreamKey
    }
}

/// Who starts muted when they join the room. A moderator writes it to the room; clients
/// read it back through `JitsiConference.startMutedPolicy` and apply it to their first capture.
public struct StartMutedPolicy: Sendable, Equatable {
    public var audio: Bool
    public var video: Bool

    public init(audio: Bool = false, video: Bool = false) {
        self.audio = audio
        self.video = video
    }
}

/// Identity the local participant publishes to the room.
///
/// `displayName` travels in the MUC presence `nick` element. `email` and `avatarURL` use the
/// `email` / `avatar-url` presence commands the jitsi-meet clients subscribe to. A participant
/// authenticated by JWT keeps the token's identity for those two fields on the receiving side,
/// because the token is authoritative there. `extras` become `jitsi_participant_<key>` presence
/// extensions, which every jitsi-meet client exposes through `getProperty(key)`.
public struct UserInfo: Sendable, Equatable {
    public var displayName: String
    public var email: String?
    public var avatarURL: String?
    /// Extra presence extensions. Keys must be valid XML element name tails (ASCII letter or
    /// underscore first, then letters, digits, `_`, `-`, `.`); `joinConference` rejects
    /// anything else instead of emitting a malformed stanza.
    public var extras: [String: String]

    public init(
        displayName: String,
        email: String? = nil,
        avatarURL: String? = nil,
        extras: [String: String] = [:]
    ) {
        self.displayName = displayName
        self.email = email
        self.avatarURL = avatarURL
        self.extras = extras
    }
}

public struct ConferenceOptions: Sendable {
    public var name: ConferenceName
    /// Nickname, avatar and other identity published with the join presence.
    public var userInfo: UserInfo
    public var enableE2EE: Bool
    /// Room password. Empty/nil for open rooms; with lobby enabled the same password is
    /// also the way a participant skips the waiting room.
    public var password: String?
    public var configOverwrite: [String: JSONValue]
    public var connectionOptions: JSONValue

    public init(
        name: ConferenceName,
        userInfo: UserInfo,
        enableE2EE: Bool = false,
        password: String? = nil,
        configOverwrite: [String: JSONValue] = [:],
        connectionOptions: JSONValue = .object([:])
    ) {
        self.name = name
        self.userInfo = userInfo
        self.enableE2EE = enableE2EE
        self.password = password
        self.configOverwrite = configOverwrite
        self.connectionOptions = connectionOptions
    }
}

public struct ConnectionOptions: Sendable {
    public var serviceUrl: String
    public var hosts: Hosts
    public var token: String?
    public var credentials: Credentials?
    /// ICE configuration lib-jitsi-meet uses for peer-to-peer calls (two participants).
    public var p2p: P2PConfiguration

    /// Peer-to-peer ICE servers.
    ///
    /// lib-jitsi-meet falls back to `stun:meet-jit-si-turnrelay.jitsi.net:443` when no list is
    /// supplied. That default is unreachable from mainland China and from private deployments,
    /// and it discloses the device's public address to a third party, so this SDK sends an
    /// explicit (empty by default) list instead. With no STUN server ICE gathers host
    /// candidates only; peers that cannot reach each other directly fall back to the
    /// conference bridge, which is the normal multi-party path anyway. Point this at your own
    /// STUN/TURN deployment when direct connections matter.
    public struct P2PConfiguration: Sendable {
        public enum TransportPolicy: String, Sendable {
            case all
            case relay
        }

        /// Zero or more `stun:` / `turn:` URLs.
        public var stunServers: [String]
        /// `relay` gathers only relayed candidates, which forces media through TURN.
        public var iceTransportPolicy: TransportPolicy?

        public init(stunServers: [String] = [], iceTransportPolicy: TransportPolicy? = nil) {
            self.stunServers = stunServers
            self.iceTransportPolicy = iceTransportPolicy
        }
    }

    public struct Hosts: Sendable {
        public var domain: String
        public var muc: String
        public var bridge: String?

        public init(domain: String, muc: String, bridge: String? = nil) {
            self.domain = domain
            self.muc = muc
            self.bridge = bridge
        }
    }

    public struct Credentials: Sendable {
        public var username: String
        public var password: String

        public init(username: String, password: String) {
            self.username = username
            self.password = password
        }
    }

    public init(
        serviceUrl: String,
        hosts: Hosts,
        token: String? = nil,
        credentials: Credentials? = nil,
        p2p: P2PConfiguration = P2PConfiguration()
    ) {
        self.serviceUrl = serviceUrl
        self.hosts = hosts
        self.token = token
        self.credentials = credentials
        self.p2p = p2p
    }
}

/// Passthrough for the JS objects whose shape the SDK does not model yet.
public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from data: Data) throws {
        self = try JSONValue.decode(JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    public var encoded: Data {
        get throws { try JSONSerialization.data(withJSONObject: nsObject, options: [.fragmentsAllowed]) }
    }

    /// Bridged through `NSJSONSerialization` rather than `JSONEncoder`, because JS payloads
    /// arriving from `JSValue` are already Foundation objects.
    internal var nsObject: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let v): return v
        case .number(let v): return v
        case .string(let v): return v
        case .array(let v): return v.map(\.nsObject)
        case .object(let v): return v.mapValues(\.nsObject)
        }
    }

    private static func decode(_ raw: Any) throws -> JSONValue {
        switch raw {
        case is NSNull: return .null
        case let v as Bool: return .bool(v)
        case let v as NSNumber: return .number(v.doubleValue)
        case let v as String: return .string(v)
        case let v as [Any]: return .array(try v.map(decode))
        case let v as [String: Any]: return .object(try v.mapValues(decode))
        default: throw JSONDecodingError(debugDescription: "unsupported JSON leaf: \(String(describing: raw))")
        }
    }

    public struct JSONDecodingError: Error {
        public var debugDescription: String

        public init(debugDescription: String) {
            self.debugDescription = debugDescription
        }
    }
}
