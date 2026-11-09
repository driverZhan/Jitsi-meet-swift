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

    public init(
        id: ParticipantID,
        displayName: String,
        role: ParticipantRole = .participant,
        isLocal: Bool = false,
        raisedHand: Bool = false,
        tracks: [TrackSnapshot] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.role = role
        self.isLocal = isLocal
        self.raisedHand = raisedHand
        self.tracks = tracks
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

public struct ConferenceOptions: Sendable {
    public var name: ConferenceName
    public var displayName: String
    public var email: String?
    public var avatarURL: String?
    public var enableE2EE: Bool
    public var configOverwrite: [String: JSONValue]
    public var connectionOptions: JSONValue

    public init(
        name: ConferenceName,
        displayName: String,
        email: String? = nil,
        avatarURL: String? = nil,
        enableE2EE: Bool = false,
        configOverwrite: [String: JSONValue] = [:],
        connectionOptions: JSONValue = .object([:])
    ) {
        self.name = name
        self.displayName = displayName
        self.email = email
        self.avatarURL = avatarURL
        self.enableE2EE = enableE2EE
        self.configOverwrite = configOverwrite
        self.connectionOptions = connectionOptions
    }
}

public struct ConnectionOptions: Sendable {
    public var serviceUrl: String
    public var hosts: Hosts
    public var token: String?
    public var credentials: Credentials?

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

    public init(serviceUrl: String, hosts: Hosts, token: String? = nil, credentials: Credentials? = nil) {
        self.serviceUrl = serviceUrl
        self.hosts = hosts
        self.token = token
        self.credentials = credentials
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
