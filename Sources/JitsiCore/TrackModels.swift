import Foundation

public enum LocalTrackState: String, Sendable {
    case pending
    case live
    case muted
    case ended
}

/// Runtime capture constraints. Only the fields a phone camera can change without
/// replacing the track are modelled: the resolution and the frame rate.
public struct VideoConstraints: Sendable, Equatable {
    public var width: Int?
    public var height: Int?
    public var frameRate: Int?

    public init(width: Int? = nil, height: Int? = nil, frameRate: Int? = nil) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
    }
}

/// What the active camera can do, and what it is doing now. The format list is the source
/// the UI can offer as resolution choices; `active*` is what a later `apply` actually picked.
public struct VideoTrackCapabilities: Sendable, Equatable {
    public struct Format: Sendable, Equatable {
        public var width: Int
        public var height: Int
        public var minFrameRate: Double
        public var maxFrameRate: Double

        public init(width: Int, height: Int, minFrameRate: Double, maxFrameRate: Double) {
            self.width = width
            self.height = height
            self.minFrameRate = minFrameRate
            self.maxFrameRate = maxFrameRate
        }
    }

    public var formats: [Format]
    public var activeWidth: Int?
    public var activeHeight: Int?
    public var activeFrameRate: Double?
    public var deviceID: String?

    public init(
        formats: [Format] = [],
        activeWidth: Int? = nil,
        activeHeight: Int? = nil,
        activeFrameRate: Double? = nil,
        deviceID: String? = nil
    ) {
        self.formats = formats
        self.activeWidth = activeWidth
        self.activeHeight = activeHeight
        self.activeFrameRate = activeFrameRate
        self.deviceID = deviceID
    }
}

/// Per-source receiver constraints for the bridge. The lib updates only the fields that are
/// present, so nil/empty values leave the previous hint untouched.
public struct ReceiverConstraints: Sendable, Equatable {
    /// Number of remote videos to forward; -1 means unlimited.
    public var lastN: Int?
    /// Height cap for every source without a per-source entry.
    public var defaultMaxHeight: Int?
    /// Per-source height cap, keyed by the track's `sourceName`.
    public var sourceMaxHeights: [String: Int]
    /// Bandwidth hint in bits per second, used by the bridge when picking resolutions.
    public var assumedBandwidthBps: Int?

    public init(
        lastN: Int? = nil,
        defaultMaxHeight: Int? = nil,
        sourceMaxHeights: [String: Int] = [:],
        assumedBandwidthBps: Int? = nil
    ) {
        self.lastN = lastN
        self.defaultMaxHeight = defaultMaxHeight
        self.sourceMaxHeights = sourceMaxHeights
        self.assumedBandwidthBps = assumedBandwidthBps
    }
}

/// Built-in output route. Headphones, Bluetooth and CarPlay win over this choice while they
/// are connected; the setting decides between the receiver and the loudspeaker otherwise.
/// Browsers expose this as `setAudioOutputDevice`, which needs `setSinkId`; the native
/// backend drives `AVAudioSession` instead.
public enum AudioOutputRoute: String, Sendable, Equatable {
    case receiver
    case speaker
}

public struct PreCallTestServer: Sendable, Equatable {
    public var urls: [String]
    public var username: String?
    public var credential: String?

    public init(urls: [String], username: String? = nil, credential: String? = nil) {
        self.urls = urls
        self.username = username
        self.credential = credential
    }
}

/// Result of the lib's TURN/data-channel pre-call probe. Metrics are nil when that part of
/// the test could not run (for example the throughput test in the React Native path).
public struct PreCallTestResult: Sendable, Equatable {
    /// A relay candidate was established; the deployment's TURN path is reachable.
    public var mediaConnectivity: Bool
    /// Average throughput in kbps.
    public var throughput: Double?
    /// Lost bytes as a fraction of the test traffic.
    public var fractionalLoss: Double?
    /// Median round-trip time in milliseconds.
    public var rtt: Double?
    /// Round-trip variance in milliseconds.
    public var jitter: Double?

    public init(
        mediaConnectivity: Bool = false,
        throughput: Double? = nil,
        fractionalLoss: Double? = nil,
        rtt: Double? = nil,
        jitter: Double? = nil
    ) {
        self.mediaConnectivity = mediaConnectivity
        self.throughput = throughput
        self.fractionalLoss = fractionalLoss
        self.rtt = rtt
        self.jitter = jitter
    }
}

public struct LocalTrack: Identifiable, Sendable {
    public let id: TrackID
    public let snapshot: TrackSnapshot
    public var state: LocalTrackState

    public var mediaType: MediaType { snapshot.mediaType }
    public var muted: Bool { snapshot.muted }
}

public struct RemoteTrack: Identifiable, Sendable {
    public let snapshot: TrackSnapshot
    public let owner: ParticipantID
    public var muted: Bool

    public var id: TrackID { snapshot.id }
    public var mediaType: MediaType { snapshot.mediaType }
    public var videoType: VideoType { snapshot.videoType }
}

/// Reference type on purpose: participants mutate as presence arrives, and the conference
/// keeps one instance per JID so the UI can diff identity-stable rows. Not `Sendable`;
/// `JitsiConference` confines it to the main actor.
public final class JitsiParticipant: Identifiable {
    public let id: ParticipantID
    public private(set) var snapshot: ParticipantSnapshot

    public var displayName: String { snapshot.displayName }
    public var role: ParticipantRole { snapshot.role }
    public var isModerator: Bool { snapshot.role == .moderator || snapshot.role == .owner }
    public var raisedHand: Bool { snapshot.raisedHand }
    public var avatarURL: String? { snapshot.avatarURL }
    public var email: String? { snapshot.email }
    public var jid: String { snapshot.jid }
    public var connectionJID: String? { snapshot.connectionJID }
    public var status: String { snapshot.status }
    public var botType: String? { snapshot.botType }
    public var statsID: String { snapshot.statsID }
    public var isSilent: Bool { snapshot.isSilent }
    public var isReplacing: Bool { snapshot.isReplacing }
    public var isReplaced: Bool { snapshot.isReplaced }
    public var isHidden: Bool { snapshot.isHidden }
    public var isAudioMuted: Bool { snapshot.isAudioMuted }
    public var isVideoMuted: Bool { snapshot.isVideoMuted }

    init(snapshot: ParticipantSnapshot) {
        self.id = snapshot.id
        self.snapshot = snapshot
    }

    func apply(_ updated: ParticipantSnapshot) {
        snapshot = updated
    }
}
