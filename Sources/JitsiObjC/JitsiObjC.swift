import AVFoundation
import Foundation
import JitsiCore
import JitsiMeetSDK
import SwiftUI
import UIKit

/// How a canvas scales the incoming frame into its bounds.
@objc public enum JitsiCanvasFillMode: Int {
    /// Crops the frame to cover the canvas; the default.
    case fill
    /// Letterboxes the whole frame so no pixel is lost.
    case fit
}

/// Verbosity of the lib-jitsi-meet log, passed to `bootstrap`.
@objc public enum JitsiLogLevel: Int {
    case trace
    case debug
    case info
    /// `warn` in the JS bundle.
    case warning
    case error

    /// The name `lib-jitsi-meet` expects in `JitsiMeetJS.init`.
    var jsLogLevel: String {
        switch self {
        case .trace: return "trace"
        case .debug: return "debug"
        case .info: return "info"
        case .warning: return "warn"
        case .error: return "error"
        }
    }
}

/// Canvas appearance for the ObjC façade.
///
/// Each canvas starts from `JitsiSDK.defaultCanvasStyle`; override one participant with
/// `JitsiSDK.setCanvasStyle(_:forParticipant:)` (use `"local"` for the self-view). Changes are
/// applied live to canvases already on screen. Positions accept `"center"`, `"topLeading"`,
/// `"topTrailing"`, `"bottomLeading"` or `"bottomTrailing"`.
@objcMembers
public final class JitsiCanvasStyle: NSObject {
    /// Rounded corners of the tile, in points.
    public var cornerRadius: CGFloat = 12 { didSet { notifyChange() } }
    /// `.fill` crops to cover, `.fit` letterboxes the whole frame.
    public var fillMode: JitsiCanvasFillMode = .fill { didSet { notifyChange() } }
    public var showsName: Bool = true { didSet { notifyChange() } }
    /// The avatar drawn while the camera is off (or before the first frame).
    public var showsAvatar: Bool = true { didSet { notifyChange() } }
    /// Red `mic.slash` while muted, the level meter while open.
    public var showsMicrophoneBadge: Bool = true { didSet { notifyChange() } }
    /// The moving level meter left of the name. Off keeps the caption still while the
    /// participant talks; the mute icon is still controlled by `showsMicrophoneBadge`.
    public var showsAudioLevel: Bool = true { didSet { notifyChange() } }
    /// The connection-quality bars in the top-left corner.
    public var showsConnectionBadge: Bool = true { didSet { notifyChange() } }
    /// Avatar diameter while the camera is off, in points.
    public var avatarSize: CGFloat = 64 { didSet { notifyChange() } }
    /// Where the avatar sits while the camera is off.
    public var avatarPosition: String = "center" { didSet { notifyChange() } }
    /// Where the caption row (microphone meter + name) sits.
    public var namePosition: String = "bottomLeading" { didSet { notifyChange() } }
    /// Name text size, in points.
    public var nameFontSize: CGFloat = 13 { didSet { notifyChange() } }

    fileprivate var onChange: (() -> Void)?

    public override init() {
        super.init()
    }

    /// A style carrying the documented defaults.
    public static func defaultStyle() -> JitsiCanvasStyle {
        JitsiCanvasStyle()
    }

    private func notifyChange() {
        onChange?()
    }
}

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

    /// Set before `bootstrap`. Injects the custom audio device (README §12.5); a value
    /// change after the engine is installed needs `shutdown()` first.
    public var useCustomAudioDevice = false
    /// Reads at `bootstrap`, like `useCustomAudioDevice`. Off: a remote screen share gets its
    /// own canvas (id `"<participantID>-screen"`, named "<name> 的屏幕") next to the camera
    /// canvas. On: the share replaces the camera inside that participant's single canvas.
    public var mergesRemoteScreenShareWithCamera = false

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
    /// Output route audio is on now: `"receiver"`, `"speaker"`, `"headphones"`,
    /// `"bluetooth"` or `"carPlay"`. External routes win while connected.
    public private(set) var audioOutputRoute: String?
    /// True between `preparePreview…` and entering the room: local capture runs and the
    /// self-view is live, but nothing has been published to the room.
    public private(set) var isPreviewing = false
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

    // MARK: - Canvas layout

    /// Appearance shared by every canvas without a per-participant override. Mutating it
    /// updates canvases already on screen.
    public let defaultCanvasStyle = JitsiCanvasStyle()

    /// Per-participant overrides; `"local"` is the self-view. Kept until cleared with a
    /// nil style or replaced by a later join of the same id.
    private var canvasStyleOverrides: [String: JitsiCanvasStyle] = [:]

    /// Shorthand for `defaultCanvasStyle.cornerRadius`, kept for existing callers.
    public var canvasCornerRadius: CGFloat {
        get { defaultCanvasStyle.cornerRadius }
        set { defaultCanvasStyle.cornerRadius = newValue }
    }
    /// Shorthand for `defaultCanvasStyle.fillMode`: `.fill` (default) crops to cover,
    /// `.fit` letterboxes the whole frame.
    public var canvasFillMode: JitsiCanvasFillMode {
        get { defaultCanvasStyle.fillMode }
        set { defaultCanvasStyle.fillMode = newValue }
    }
    public var canvasShowsName: Bool {
        get { defaultCanvasStyle.showsName }
        set { defaultCanvasStyle.showsName = newValue }
    }
    public var canvasShowsMicrophoneBadge: Bool {
        get { defaultCanvasStyle.showsMicrophoneBadge }
        set { defaultCanvasStyle.showsMicrophoneBadge = newValue }
    }
    public var canvasShowsConnectionBadge: Bool {
        get { defaultCanvasStyle.showsConnectionBadge }
        set { defaultCanvasStyle.showsConnectionBadge = newValue }
    }
    public var canvasAvatarSize: CGFloat {
        get { defaultCanvasStyle.avatarSize }
        set { defaultCanvasStyle.avatarSize = newValue }
    }
    public var canvasAvatarPosition: String {
        get { defaultCanvasStyle.avatarPosition }
        set { defaultCanvasStyle.avatarPosition = newValue }
    }
    public var canvasNamePosition: String {
        get { defaultCanvasStyle.namePosition }
        set { defaultCanvasStyle.namePosition = newValue }
    }
    public var canvasNameFontSize: CGFloat {
        get { defaultCanvasStyle.nameFontSize }
        set { defaultCanvasStyle.nameFontSize = newValue }
    }

    /// Gives one canvas its own appearance. `participantID` is the id delivered by
    /// `jitsiDidJoinRemoteCanvas:…`, or `"local"` for the self-view. Pass nil to restore
    /// `defaultCanvasStyle` for that id. Applies live, including already-delivered canvases,
    /// and is remembered if the participant joins later.
    public func setCanvasStyle(_ style: JitsiCanvasStyle?, forParticipant participantID: String) {
        guard let style else {
            canvasStyleOverrides[participantID] = nil
            applyCanvasStyle(forParticipant: participantID)
            return
        }
        style.onChange = { [weak self] in
            Task { @MainActor in
                self?.applyCanvasStyle(forParticipant: participantID)
            }
        }
        canvasStyleOverrides[participantID] = style
        applyCanvasStyle(forParticipant: participantID)
    }

    /// Display-only meeting limit in seconds. The server's `time_restricted` message wins
    /// when the deployment enforces one; 0 means "no host limit".
    public var meetingTimeLimit: TimeInterval = 0

    /// Latest start anchor and time limit. Refreshed if a server source arrives after the
    /// one-shot `jitsiDidJoinMeetingTiming:` callback.
    public private(set) var meetingTiming: MeetingTiming?

    /// Seconds since the meeting started, anchored on the server clock when available.
    public var meetingElapsedSeconds: TimeInterval { meetingElapsedSeconds(at: Date()) }

    /// Seconds until the limit; negative past it. Nil when no limit is known.
    public var meetingRemainingSeconds: NSNumber? { meetingRemainingSeconds(at: Date()) }

    public func meetingElapsedSeconds(at date: Date) -> TimeInterval {
        meetingTiming?.elapsed(at: date) ?? 0
    }

    public func meetingRemainingSeconds(at date: Date) -> NSNumber? {
        meetingTiming?.remaining(at: date).map { NSNumber(value: $0) }
    }

    /// Late-lookup path for a remote canvas. The view is the same one delivered to
    /// `jitsiDidJoinRemoteCanvas:…`, so adding it to another host moves the live canvas.
    public func canvasView(forParticipant participantID: String) -> UIView? {
        guard let model = canvasModels[participantID] else { return nil }
        return canvasHost(forParticipant: participantID, model: model).view
    }

    /// Live self-view, for the prejoin screen and for the in-room "you" tile. Nil until
    /// `preparePreview…` (or `joinRoom`) opened local capture. The view follows mute,
    /// camera and speaking state on its own; the host only adds it and gives it a frame.
    /// It is created once per preview, so a caller can move the same view between screens.
    public var localCanvasView: UIView? {
        guard let model = localCanvasModel else { return nil }
        return localCanvasHost(for: model).view
    }

    private var conference: JitsiConference?
    /// Non-nil between `startLocalRecording` and the stop that finishes the file.
    private var localRecording: JitsiLocalRecording?
    /// Non-nil between `startScreenRecording` and its stop.
    private var screenRecorder: ScreenRecorder?
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
    private static let speakingThreshold = 0.05
    /// Latest 0...1 audio level per participant, keyed by MUC id with `"local"` for this
    /// endpoint. Kept out of `publishState` so the 5 Hz level feed does not flood the
    /// delegate's state channel.
    private var participantAudioLevels: [String: Double] = [:]
    /// Polls `AudioLevelMonitor` for the self-view while the lib reports no local level.
    private var levelTimer: Timer?
    /// Last time the lib reported a level per participant, so the device fallback only takes
    /// over where the lib is silent.
    private var libLevelAt: [String: Date] = [:]
    private var loggedDeviceLevel = false
    /// Last logged canvas track selection per participant, so the trace prints on change only.
    private var loggedCanvasSelection: [String: String] = [:]
    /// When a canvas started holding its last frame because the far end lost all video tracks.
    private var holdSince: [String: Date] = [:]
    /// Upper bound on that hold; the device measured ~18 s between a share stopping and the
    /// camera publishing frames again. Past this the canvas falls back to the avatar.
    private static let videoHoldLimit: TimeInterval = 30
    /// Live canvas models keyed by MUC id. The façade retains one hosting controller per id,
    /// so a late `canvasViewForParticipant:` returns the view that is already on screen.
    private var canvasModels: [String: CanvasModel] = [:]
    private var canvasHosts: [String: UIHostingController<RemoteCanvasHost>] = [:]
    private var localCanvasModel: CanvasModel?
    private var localCanvasHostCache: UIHostingController<LocalCanvasHost>?
    /// Per-participant quality figures from the lib's stats, `"local"` for this endpoint.
    private var participantQualityLevels: [String: Int] = [:]
    /// Last delivered mute flags, so joins seed silently and only real changes are reported.
    private var knownParticipantMedia: [String: (audio: Bool, video: Bool)] = [:]
    private var muteBatchWindow: [MediaType: Set<String>] = [:]
    private var muteBatchTasks: [MediaType: Task<Void, Never>] = [:]
    private static let muteBatchWindowNanos: UInt64 = 800_000_000
    private static let muteBatchMinimumParticipants = 2
    /// Meeting clock sources, mirroring `MeetingSession`: server room-creation timestamp,
    /// the limit message's own clock, and this endpoint's join time as the last resort.
    private var serverCreatedAt: Date?
    private var restrictedLimit: (duration: TimeInterval, startedAt: Date)?
    private var localJoinedAt: Date?
    private var timingDeliveryTask: Task<Void, Never>?
    private var hasDeliveredMeetingTiming = false
    private static let membersOnlyError = "conference.connectionError.membersOnly"
    private static let accessDeniedError = "conference.connectionError.accessDenied"
    private static let passwordRequiredError = "conference.passwordRequired"
    private static let waitingForModeratorMessage = "Waiting for a moderator to let you in…"
    private static let waitingForHostMessage = "Waiting for the host to start the meeting…"
    private static let passwordRequiredMessage = "This room requires a password."

    private override init() {
        super.init()
        defaultCanvasStyle.onChange = { [weak self] in
            Task { @MainActor in
                self?.applyDefaultCanvasStyle()
            }
        }
    }

    // MARK: - Lifecycle

    /// Installs the JS engine. Call once, before `connect`.
    public func bootstrap(
        conferenceHost: String,
        logLevel: JitsiLogLevel = .info,
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
                        logLevel: logLevel.jsLogLevel,
                        debugSignaling: debugSignaling,
                        useCustomAudioDevice: useCustomAudioDevice,
                        mergesRemoteScreenShareWithCamera: mergesRemoteScreenShareWithCamera
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
        cancelLocalRecording()
        conference = nil
        participantAudioLevels = [:]
        discardRemoteCanvases(notify: false)
        resetMeetingTiming()
        connectionOptions = nil
        lastJoin = nil
        isConnected = false
        isJoined = false
        isPreviewing = false
        isScreenSharing = false
        isMediaInterrupted = false
        audioOutputRoute = nil
        discardLocalCanvas()
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
        connect(
            serviceURL: serviceURL,
            domain: domain,
            muc: muc,
            token: token,
            username: username,
            password: password,
            transport: ServerAddress.Transport.auto.rawValue,
            completion: completion
        )
    }

    /// `transport` is `auto`, `websocket` or `bosh`. The URL may carry either endpoint:
    /// `auto` races the derived WebSocket and BOSH forms, a pinned transport normalises the
    /// URL to its own form, so picking BOSH still works when the field shows a `wss://` URL.
    public func connect(
        serviceURL: String,
        domain: String,
        muc: String,
        token: String?,
        username: String?,
        password: String?,
        transport: String,
        completion: @escaping (NSError?) -> Void
    ) {
        guard let transportKind = ServerAddress.Transport(rawValue: transport.lowercased()) else {
            completion(Self.nsError(JitsiError.invalidArgument("transport must be auto, websocket or bosh")))
            return
        }
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
            p2p: ConnectionOptions.P2PConfiguration(stunServers: p2pSTUNServers),
            transport: transportKind
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
        discardRemoteCanvases(notify: true)
        resetMeetingTiming()
        isPreviewing = false
        discardLocalCanvas()
        Task {
            await JitsiMeet.shared.engine?.disconnect()
            conference = nil
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
    ///
    /// `audio` and `video` are the join-time mute choice, not whether capture runs. Both
    /// local tracks are always created and the disabled ones are muted before joining, so
    /// `setAudioMuted:` / `setVideoMuted:` can turn them back on in the room.
    ///
    /// This is `preparePreview…` followed by `joinPreparedRoom…`; call those two directly
    /// when the app shows a prejoin screen with the live self-view.
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
        preparePreview(
            roomName,
            displayName: displayName,
            email: email,
            avatarURL: avatarURL,
            audio: audio,
            video: video
        ) { [weak self] error in
            guard let self else {
                completion(error ?? Self.nsError(JitsiError.engineNotInstalled))
                return
            }
            if let error {
                completion(error)
                return
            }
            self.joinPreparedRoom(password: password, completion: completion)
        }
    }

    /// Prepares the room and opens the camera/microphone without joining. The room stays
    /// unpublished: the app shows `localCanvasView` as a live self-view, lets the
    /// user settle the mute choices, then calls `joinPreparedRoom…` and never re-captures,
    /// so the camera does not flash between the preview and the room.
    ///
    /// `audio`/`video` seed the mute state. A denied permission drops only that medium from
    /// the preview instead of failing the call, so an app can explain the denial and still
    /// join with the other one.
    public func preparePreview(
        _ roomName: String,
        displayName: String,
        email: String? = nil,
        avatarURL: String? = nil,
        audio: Bool = true,
        video: Bool = true,
        completion: @escaping (NSError?) -> Void
    ) {
        resetRejoinState()
        discardRemoteCanvases(notify: false)
        resetMeetingTiming()
        Task {
            guard let engine = JitsiMeet.shared.engine else {
                completion(Self.nsError(JitsiError.engineNotInstalled))
                return
            }
            let options = ConferenceOptions(
                name: roomName,
                userInfo: UserInfo(displayName: displayName, email: email, avatarURL: avatarURL)
            )
            let room = JitsiConference(options: options)
            room.onStateChange = { [weak self] in
                Task { @MainActor in self?.publishState() }
            }
            conference = room
            participantAudioLevels = [:]
            lastJoin = (options, audio, video)
            mainJoin = options
            isNetworkOnline = engine.isNetworkOnline
            isAudioMuted = !audio
            isVideoMuted = !video
            do {
                // Tracks registered before the join end up in the session answer; adding
                // them after leaves the native senders empty.
                try await engine.prepareConference(options)
                let captured = try await openPreviewCapture(room)
                if captured.contains(.audio) {
                    try await room.setMuted(!audio, mediaType: .audio)
                } else {
                    isAudioMuted = true
                }
                if captured.contains(.video) {
                    try await room.setMuted(!video, mediaType: .video)
                } else {
                    isVideoMuted = true
                }
                isPreviewing = true
                publishState()
                completion(nil)
            } catch {
                await cancelPreview(room)
                completion(Self.nsError(error))
            }
        }
    }

    /// Enters the room prepared by `preparePreview…`. `password` overrides whatever the
    /// preview carried; pass nil for open rooms. Capture is reused, so the preview becomes
    /// the call.
    public func joinPreparedRoom(password: String? = nil, completion: @escaping (NSError?) -> Void) {
        guard let room = conference, let engine = JitsiMeet.shared.engine, let join = lastJoin else {
            completion(Self.nsError(JitsiError.notInConference))
            return
        }
        var options = room.options
        options.password = password?.isEmpty == false ? password : nil
        lastJoin = (options, join.audio, join.video)
        mainJoin = options
        Task {
            // The prejoin controls may have moved while the preview was live.
            for (_, track) in room.localTracks {
                guard track.mediaType == .audio || track.mediaType == .video else { continue }
                let muted = track.mediaType == .audio ? isAudioMuted : isVideoMuted
                guard track.snapshot.muted != muted else { continue }
                try? await room.setMuted(muted, mediaType: track.mediaType)
            }
            do {
                try await engine.joinConference(options)
                isJoined = true
                isPreviewing = false
                publishState()
                completion(nil)
            } catch {
                completion(Self.nsError(error))
            }
        }
    }

    /// Cancels the prejoin preview and releases the camera/microphone while staying
    /// connected. `joinRoom…` will capture again if the user comes back to the room.
    public func stopPreview() {
        guard isPreviewing, let room = conference else { return }
        let engine = JitsiMeet.shared.engine
        isPreviewing = false
        lastJoin = nil
        mainJoin = nil
        cancelLocalRecording()
        conference = nil
        isAudioMuted = false
        isVideoMuted = false
        participantAudioLevels["local"] = nil
        discardLocalCanvas()
        publishState()
        Task {
            await room.leave()
            if let engine {
                for trackID in room.localTracks.keys {
                    try? await engine.closeCapture([trackID])
                }
            }
        }
    }

    /// Captures what the device allows. Both tracks are opened even when the user starts
    /// muted, because the in-room controls toggle them; a denied permission only removes
    /// its own medium.
    private func openPreviewCapture(_ room: JitsiConference) async throws -> [MediaType] {
        do {
            _ = try await room.capture([.audio, .video])
            return [.audio, .video]
        } catch {
            // A denial travels through JS, which flattens the native error into its
            // description, so the typed case is only visible as `captureDenied(…)`.
            guard let denied = previewDeniedMediaType(error) else { throw error }
            let remaining = [MediaType.audio, .video].filter { $0 != denied }
            guard !remaining.isEmpty else { throw error }
            _ = try await room.capture(remaining)
            return remaining
        }
    }

    private func previewDeniedMediaType(_ error: Error) -> MediaType? {
        if case JitsiError.captureDenied(let type) = error { return type }
        guard case JitsiError.remote(let detail) = error, detail.contains("captureDenied") else {
            return nil
        }
        return detail.contains("MediaType.video") ? .video : .audio
    }

    private func cancelPreview(_ room: JitsiConference) async {
        await room.leave()
        if let engine = JitsiMeet.shared.engine {
            for trackID in room.localTracks.keys {
                try? await engine.closeCapture([trackID])
            }
        }
        guard conference === room else { return }
        cancelLocalRecording()
        conference = nil
        lastJoin = nil
        mainJoin = nil
        isPreviewing = false
        isAudioMuted = false
        isVideoMuted = false
        discardLocalCanvas()
        publishState()
    }

    public func leave() {
        levelTimer?.invalidate()
        levelTimer = nil
        loggedDeviceLevel = false
        resetRejoinState()
        cancelLocalRecording()
        switchTask?.cancel()
        switchTask = nil
        isSwitchingRoom = false
        lastJoin = nil
        mainJoin = nil
        isPreviewing = false
        discardLocalCanvas()
        Task {
            await conference?.leave()
            await JitsiMeet.shared.engine?.disconnect()
            conference = nil
            participantAudioLevels = [:]
            libLevelAt = [:]
            loggedCanvasSelection = [:]
            holdSince = [:]
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

    /// Requests `speaker` or `receiver`. Headphones, Bluetooth and CarPlay keep priority
    /// while connected and appear in `audioOutputRoute`; other values are rejected.
    public func setAudioOutputRoute(
        _ route: String,
        completion: @escaping (NSError?) -> Void
    ) {
        guard let parsed = AudioOutputRoute(rawValue: route), parsed.isBuiltIn else {
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

    // MARK: - Local recording

    /// Whether a local recording is running.
    public var isLocalRecording: Bool { localRecording != nil }

    /// Records the conference board to an MP4 in the app's caches directory: the local
    /// self-view as the stage, remote videos in a grid. When the engine was bootstrapped with
    /// `useCustomAudioDevice`, the mixed microphone + remote audio is written as an AAC track;
    /// otherwise the file is video-only.
    ///
    /// The finished URL arrives at `JitsiSDKDelegate.jitsiDidFinishLocalRecording:error:` and
    /// at the stop completion. Leaving the call cancels the recording and deletes the file.
    public func startLocalRecording(completion: @escaping (NSError?) -> Void) {
        guard conference != nil else {
            completion(Self.recordingError("Join a conference before recording."))
            return
        }
        guard localRecording == nil else {
            completion(Self.recordingError("A local recording is already running."))
            return
        }
        let canvas = CGSize(width: 1280, height: 720)
        let recording = JitsiLocalRecording(
            outputURL: Self.localRecordingURL(),
            canvas: canvas
        ) { [weak self] in
            self?.recordingTiles(canvas: canvas) ?? []
        }
        Task { @MainActor in
            do {
                try await recording.start(audio: JitsiMeet.shared.config.useCustomAudioDevice)
                self.localRecording = recording
                completion(nil)
            } catch {
                completion(Self.nsError(error))
            }
        }
    }

    /// Finishes the file and reports its URL. `fileURL` is nil when the writer failed.
    public func stopLocalRecording(completion: @escaping (NSURL?, NSError?) -> Void) {
        guard let recording = localRecording else {
            completion(nil, Self.recordingError("No local recording is running."))
            return
        }
        localRecording = nil
        Task { @MainActor in
            do {
                let url = try await recording.stop()
                self.delegate?.jitsiDidFinishLocalRecording?(url as NSURL, error: nil)
                completion(url as NSURL, nil)
            } catch {
                let nsError = Self.nsError(error)
                self.delegate?.jitsiDidFinishLocalRecording?(nil, error: nsError)
                completion(nil, nsError)
            }
        }
    }

    /// The tiles the recorder composites for the current conference state. Muted cameras are
    /// skipped, matching the canvas behaviour (avatar instead of a dead track).
    private func recordingTiles(canvas: CGSize) -> [RecordingTile] {
        guard let conference else { return [] }
        let localTrackID: TrackID? = isVideoMuted ? nil : localVideoTrack?.id
        let remoteTrackIDs = conference.participants.values
            .filter { $0.id != conference.localParticipantID }
            .sorted { $0.id < $1.id }
            .compactMap { participant in
                participant.snapshot.tracks.first {
                    $0.mediaType == .video && $0.videoType != .desktop && !$0.muted
                }?.id
            }
        return JitsiLocalRecording.layout(
            localTrackID: localTrackID,
            remoteTrackIDs: remoteTrackIDs,
            canvas: canvas
        )
    }

    // MARK: - Screen recording (WYSIWYG)

    /// Whether a ReplayKit screen recording is running.
    public var isScreenRecording: Bool { screenRecorder?.isRecording ?? false }

    /// Records what the app shows, exactly as the user sees it. Audio still comes from the
    /// injected audio device (mixed microphone + remote), so the file is one MP4 with screen
    /// video and a 48 kHz AAC track. Needs a foreground app and a real device.
    ///
    /// `jitsiDidFinishLocalRecording:error:` and the stop completion both receive the URL.
    public func startScreenRecording(completion: @escaping (NSError?) -> Void) {
        guard conference != nil else {
            completion(Self.recordingError("Join a conference before recording."))
            return
        }
        guard screenRecorder == nil else {
            completion(Self.recordingError("A screen recording is already running."))
            return
        }
        let configuration = ScreenRecordingConfiguration(
            outputURL: Self.screenRecordingURL(),
            frameRate: 24,
            videoBitrate: 6_000_000,
            audio: JitsiMeet.shared.config.useCustomAudioDevice ? AudioRecordingOptions() : nil
        )
        let recorder = ScreenRecorder(configuration: configuration)
        screenRecorder = recorder
        Task { @MainActor in
            do {
                try await recorder.start()
                completion(nil)
            } catch {
                self.screenRecorder = nil
                completion(Self.nsError(error))
            }
        }
    }

    /// Finishes the screen recording and reports its URL.
    public func stopScreenRecording(completion: @escaping (NSURL?, NSError?) -> Void) {
        guard let recorder = screenRecorder else {
            completion(nil, Self.recordingError("No screen recording is running."))
            return
        }
        screenRecorder = nil
        Task { @MainActor in
            do {
                let url = try await recorder.stop()
                self.delegate?.jitsiDidFinishLocalRecording?(url as NSURL, error: nil)
                completion(url as NSURL, nil)
            } catch {
                let nsError = Self.nsError(error)
                self.delegate?.jitsiDidFinishLocalRecording?(nil, error: nsError)
                completion(nil, nsError)
            }
        }
    }

    private func cancelLocalRecording() {
        if let localRecording {
            localRecording.cancel()
            self.localRecording = nil
        }
        if let screenRecorder {
            screenRecorder.cancel()
            self.screenRecorder = nil
        }
    }

    private static func localRecordingURL() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("jitsi-recording-\(timestamp()).mp4")
    }

    private static func screenRecordingURL() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("jitsi-screen-\(timestamp()).mp4")
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private static func recordingError(_ message: String) -> NSError {
        NSError(
            domain: "org.jitsi.sdk.recording",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
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

    /// Participant rows: `id`, `displayName`, `role`, `raisedHand`, `tracks`, mic/camera
    /// mute flags, and the live `audioLevel`/`isSpeaking` pair.
    public func participants() -> [[String: Any]] {
        conference?.participants.values.map { participant in
            var row = Self.participantDictionary(participant)
            let level = participantAudioLevels[participant.id] ?? 0
            row["audioLevel"] = level
            row["isSpeaking"] = level >= Self.speakingThreshold && !participant.isAudioMuted
            return row
        } ?? []
    }

    /// Latest 0...1 microphone level per participant; `"local"` is this endpoint.
    public func audioLevels() -> [String: Double] {
        participantAudioLevels
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
                // Both tracks are rebuilt even when the user entered muted, so the
                // controls can enable them after the rejoin as well.
                _ = try await room.capture([.audio, .video])
                if isAudioMuted { try? await room.setMuted(true, mediaType: .audio) }
                if isVideoMuted { try? await room.setMuted(true, mediaType: .video) }
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
        startLevelTimer()
    }

    /// Drives the self-view meter from the audio device while the lib reports nothing: its
    /// WebAudio analyser needs an `AudioContext` that WKWebView keeps suspended, so
    /// `TRACK_AUDIO_LEVEL_CHANGED` never fires for the local track there.
    private func startLevelTimer() {
        levelTimer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshDeviceLevels() }
        }
        RunLoop.main.add(timer, forMode: .common)
        levelTimer = timer
    }

    /// Fills the meters the lib leaves empty. The self-view reads the microphone RMS and every
    /// unmuted remote reads the playout mix, which is all the audio device can give us after
    /// the bridge mixed them down. A participant the lib does report keeps its own value.
    private func refreshDeviceLevels() {
        guard let conference else { return }
        let localID = conference.localParticipantID
        var touched: [String: Double] = [:]

        if Date().timeIntervalSince(libLevelAt["local"] ?? .distantPast) > 1 {
            let level = AudioLevelMonitor.shared.microphoneLevel
            if abs(level - (participantAudioLevels["local"] ?? 0)) > 0.004 {
                participantAudioLevels["local"] = level
                touched["local"] = level
            }
        }

        let playout = AudioLevelMonitor.shared.playoutLevel
        if playout > 0.004 {
            for participant in conference.participants.values
            where participant.id != localID && !participant.isAudioMuted {
                guard Date().timeIntervalSince(libLevelAt[participant.id] ?? .distantPast) > 1 else { continue }
                if abs(playout - (participantAudioLevels[participant.id] ?? 0)) > 0.004 {
                    participantAudioLevels[participant.id] = playout
                    touched[participant.id] = playout
                }
            }
        }

        guard !touched.isEmpty else { return }
        if !loggedDeviceLevel, (touched["local"] ?? 0) > 0.01 {
            loggedDeviceLevel = true
            NSLog("[levels] device mic level=%.3f", touched["local"] ?? 0)
        }
        refreshLocalCanvas()
        syncRemoteParticipants()
        delegate?.jitsiDidUpdateAudioLevels?(touched)
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
            if localJoinedAt == nil { localJoinedAt = Date() }
            recomputeMeetingTiming()
            scheduleMeetingTimingDelivery()
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
        case .audioOutputRouteChanged(let route):
            audioOutputRoute = route.rawValue
            delegate?.jitsiDidChangeAudioOutputRoute?(route.rawValue)
            publishState()
        case .conferenceLeft(let reason):
            isJoined = false
            isLocked = false
            audioOutputRoute = nil
            isWaitingForHost = false
            requiresPassword = false
            participantAudioLevels = [:]
            discardRemoteCanvases(notify: true)
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
             .trackMuteChanged, .participantMuted, .participantJoined, .participantLeft,
             .participantDisplayNameChanged, .participantAvatarChanged, .participantEmailChanged,
             .participantRoleChanged, .participantPropertyChanged, .raisedHandChanged,
             .dominantSpeakerChanged, .conferencePropertiesChanged, .lobbyUserJoined,
             .lobbyUserUpdated, .lobbyUserLeft, .avModerationApproved,
             .avModerationRejected, .avModerationParticipantApproved,
             .avModerationParticipantRejected, .breakoutRoomsUpdated:
            publishState()
        case .avModerationChanged(let enabled, let mediaType, let actor):
            if let mediaType {
                delegate?.jitsiDidChangeAVModeration?(
                    mediaType.rawValue,
                    enabled: enabled,
                    actorID: actor
                )
            }
            publishState()
        case .connectionQualityLevel(let digital, _, let participantID):
            let key = participantID ?? "local"
            if digital >= 0 { participantQualityLevels[key] = digital }
            publishState()
        case .conferenceCreatedTimestamp(let raw):
            // Milliseconds since epoch, as the backend's disco#info field carries it.
            if let milliseconds = Double(raw), milliseconds > 0 {
                serverCreatedAt = Date(timeIntervalSince1970: milliseconds / 1000)
                recomputeMeetingTiming()
                if !hasDeliveredMeetingTiming, hasCompleteTimingSources {
                    deliverMeetingTiming()
                }
            }
        case .nonParticipantMessage(let from, let text):
            // Only the room itself may set the limit; a participant echoing this payload is
            // rejected, matching the reference client.
            guard from?.isEmpty ?? true,
                  let limit = Self.parseTimeRestricted(text)
            else { break }
            restrictedLimit = (limit.duration, Date().addingTimeInterval(-limit.elapsed))
            recomputeMeetingTiming()
            if !hasDeliveredMeetingTiming, hasCompleteTimingSources {
                deliverMeetingTiming()
            }
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
        case .audioLevels(let latest):
            let localID = conference?.localParticipantID
            var normalized: [String: Double] = [:]
            for (id, raw) in latest {
                let key = id == localID ? "local" : id
                let level = raw > 1 ? raw / 100 : min(max(raw, 0), 1)
                participantAudioLevels[key] = level
                normalized[key] = level
                libLevelAt[key] = Date()
            }
            if !normalized.isEmpty {
                delegate?.jitsiDidUpdateAudioLevels?(normalized)
            }
            syncRemoteParticipants()
            refreshLocalCanvas()
        default:
            break
        }
        delegate?.jitsiDidReceiveEvent?(event.rawName, payload: event.rawPayload)
    }

    private func publishState() {
        syncRemoteParticipants()
        refreshLocalCanvas()
        delegate?.jitsiDidChangeState(stateSnapshot())
    }

    // MARK: - Remote canvases and media

    /// Keeps the self-view in step with local tracks, mute choices, speaking and camera
    /// facing. The model exists as soon as a conference is prepared, so the host can mount
    /// the controller before the first frame arrives.
    private func refreshLocalCanvas() {
        guard conference != nil else {
            discardLocalCanvas()
            return
        }
        let video = localVideoTrack
        let level = participantAudioLevels["local"] ?? 0
        let row = CanvasParticipant(
            id: "local",
            displayName: lastJoin?.options.userInfo.displayName ?? "",
            avatarURL: lastJoin?.options.userInfo.avatarURL,
            videoTrackID: isVideoMuted ? nil : video?.id,
            audioMuted: isAudioMuted,
            audioLevel: level,
            isSpeaking: !isAudioMuted && level >= Self.speakingThreshold,
            raisedHand: false,
            connectionQualityLevel: participantQualityLevels["local"]
        )
        let model: CanvasModel
        if let existing = localCanvasModel {
            model = existing
        } else {
            model = CanvasModel()
            model.style = resolvedCanvasStyle(for: "local")
            localCanvasModel = model
        }
        if model.participant != row { model.participant = row }
        let front = video?.snapshot.deviceID
            .flatMap { AVCaptureDevice(uniqueID: $0) }
            .map { $0.position == .front } ?? true
        if model.mirrored != front { model.mirrored = front }
    }

    private var localVideoTrack: LocalTrack? {
        conference?.localTracks.values.first {
            $0.mediaType == .video && $0.snapshot.videoType != .desktop
        }
    }

    private func discardLocalCanvas() {
        localCanvasModel = nil
        localCanvasHostCache = nil
    }

    /// The style a canvas with this id should draw: its override, or the default.
    private func resolvedCanvasStyle(for participantID: String) -> ParticipantCanvasStyle {
        (canvasStyleOverrides[participantID] ?? defaultCanvasStyle).participantStyle
    }

    private func applyCanvasStyle(forParticipant participantID: String) {
        let style = resolvedCanvasStyle(for: participantID)
        if participantID == "local" {
            localCanvasModel?.style = style
        } else {
            canvasModels[participantID]?.style = style
        }
    }

    /// Applies a changed `defaultCanvasStyle` to every canvas that has no override.
    private func applyDefaultCanvasStyle() {
        let style = defaultCanvasStyle.participantStyle
        var shareStyle = style
        shareStyle.showsMicrophoneBadge = false
        shareStyle.showsConnectionBadge = false
        shareStyle.speakingHighlight = .none
        for (id, model) in canvasModels where canvasStyleOverrides[id] == nil {
            model.style = isScreenCanvas(id) ? shareStyle : style
        }
        if canvasStyleOverrides["local"] == nil {
            localCanvasModel?.style = style
        }
    }

    private func canvasHost(
        forParticipant participantID: String,
        model: CanvasModel
    ) -> UIHostingController<RemoteCanvasHost> {
        if let cached = canvasHosts[participantID] { return cached }
        let controller = UIHostingController(rootView: RemoteCanvasHost(model: model))
        controller.view.backgroundColor = .black
        canvasHosts[participantID] = controller
        return controller
    }

    private func localCanvasHost(for model: CanvasModel) -> UIHostingController<LocalCanvasHost> {
        if let cached = localCanvasHostCache { return cached }
        let controller = UIHostingController(rootView: LocalCanvasHost(model: model))
        controller.view.backgroundColor = .black
        localCanvasHostCache = controller
        return controller
    }

    /// Reconciles the live canvas models against the participant list: delivers joins and
    /// leaves once, refreshes values, and reports microphone/camera flags on real changes.
    private func syncRemoteParticipants() {
        guard let conference else {
            discardRemoteCanvases(notify: false)
            return
        }
        let remotes = conference.participants.values.filter { $0.id != conference.localParticipantID }

        // A share canvas per sharing participant, unless the app asked for one canvas each.
        var shares: [String: (owner: String, trackID: TrackID, name: String)] = [:]
        var wanted = Set(remotes.map(\.id))
        if !mergesRemoteScreenShareWithCamera {
            for participant in remotes {
                guard let trackID = screenShareTrackID(for: participant) else { continue }
                let id = Self.screenCanvasID(participant.id)
                shares[id] = (
                    participant.id,
                    trackID,
                    participant.displayName.isEmpty ? "Guest" : participant.displayName
                )
                wanted.insert(id)
            }
        }

        for id in Array(canvasModels.keys) where !wanted.contains(id) {
            canvasModels[id] = nil
            canvasHosts[id] = nil
            canvasStyleOverrides[id] = nil
            knownParticipantMedia[id] = nil
            delegate?.jitsiDidLeaveRemoteParticipant?(id)
        }

        for participant in remotes {
            let id = participant.id
            let audioMuted = participant.isAudioMuted
            let videoMuted = participant.isVideoMuted
            let row = canvasParticipant(for: participant)

            if let model = canvasModels[id] {
                if model.participant != row { model.participant = row }
                if let previous = knownParticipantMedia[id] {
                    if previous.audio != audioMuted {
                        delegate?.jitsiRemoteParticipant?(id, didChangeMicrophoneMuted: audioMuted)
                        if audioMuted { noteRemoteMute(id, .audio) }
                    }
                    if previous.video != videoMuted {
                        delegate?.jitsiRemoteParticipant?(id, didChangeCameraMuted: videoMuted)
                        if videoMuted { noteRemoteMute(id, .video) }
                    }
                }
            } else {
                let model = CanvasModel()
                model.participant = row
                model.style = resolvedCanvasStyle(for: id)
                canvasModels[id] = model
                let controller = canvasHost(forParticipant: id, model: model)
                delegate?.jitsiDidJoinRemoteCanvas?(
                    controller.view,
                    participantID: id,
                    displayName: row.displayName
                )
            }
            knownParticipantMedia[id] = (audioMuted, videoMuted)
        }

        // Share canvases come last so hosts that lay out in delivery order keep the
        // participants' own tiles ahead of the screens.
        for (id, share) in shares {
            let row = CanvasParticipant(
                id: id,
                displayName: "\(share.name) 的屏幕",
                avatarURL: nil,
                videoTrackID: share.trackID,
                // The share has no audio or camera state of its own: the sharer's microphone
                // belongs to the camera canvas.
                audioMuted: true,
                audioLevel: 0,
                isSpeaking: false,
                raisedHand: false,
                connectionQualityLevel: nil
            )
            if let model = canvasModels[id] {
                if model.participant != row { model.participant = row }
            } else {
                let model = CanvasModel()
                model.participant = row
                model.style = shareCanvasStyle(for: share.owner)
                canvasModels[id] = model
                let controller = canvasHost(forParticipant: id, model: model)
                delegate?.jitsiDidJoinRemoteCanvas?(
                    controller.view,
                    participantID: id,
                    displayName: row.displayName
                )
            }
            knownParticipantMedia[id] = (true, false)
        }
    }

    /// Canvas id of a participant's screen share; mirrors `MeetingSession.screenShareTileID`.
    static func screenCanvasID(_ participantID: String) -> String { "\(participantID)-screen" }

    /// True for the synthetic share canvas of a participant.
    private func isScreenCanvas(_ canvasID: String) -> Bool {
        canvasID.hasSuffix("-screen")
    }

    private func screenShareTrackID(for participant: JitsiParticipant) -> TrackID? {
        liveVideoTracks(for: participant).first { $0.videoType == .desktop }?.id
    }

    /// One line whenever a canvas changes which track it shows, plus the live set it chose
    /// from -- enough to tell "share still listed" from "chose a dead camera".
    private func logCanvasSelection(_ participant: JitsiParticipant, live: [TrackSnapshot], chosen: TrackID?) {
        let summary = live
            .map { "\($0.videoType.rawValue)#\($0.id.suffix(6))" }
            .joined(separator: ",")
        let key = "\(chosen?.suffix(6) ?? "none")|\(summary)"
        guard loggedCanvasSelection[participant.id] != key else { return }
        loggedCanvasSelection[participant.id] = key
        NSLog("[canvas] %@ live=[%@] chosen=%@",
              participant.id, summary, chosen.map { String($0.suffix(6)) } ?? "none")
    }

    /// Live video tracks of a participant, preferring the event-fed list: `TRACK_REMOVED`
    /// prunes `JitsiConference.remoteTracks` as soon as a share stops, while the presence
    /// snapshot can keep that dead source until the next presence update. Binding to it left
    /// the canvas black after a screen share ended.
    private func liveVideoTracks(for participant: JitsiParticipant) -> [TrackSnapshot] {
        let mirrored = conference?.remoteTracks.values
            .filter { $0.owner == participant.id && $0.mediaType == .video && !$0.muted }
            .map(\.snapshot) ?? []
        if !mirrored.isEmpty { return mirrored }
        return participant.snapshot.tracks.filter { $0.mediaType == .video && !$0.muted }
    }

    /// The participant's canvas style with every per-participant badge switched off: a screen
    /// share only shows its name.
    private func shareCanvasStyle(for participantID: String) -> ParticipantCanvasStyle {
        var style = resolvedCanvasStyle(for: participantID)
        style.showsMicrophoneBadge = false
        style.showsConnectionBadge = false
        style.speakingHighlight = .none
        return style
    }

    private func canvasParticipant(for participant: JitsiParticipant) -> CanvasParticipant {
        // Mirror `MeetingSession.rebuildTiles`: skip muted tracks so a camera-off remote
        // yields `nil` (the canvas falls back to the avatar) instead of binding the surface
        // to a dead track that renders a frozen/black frame. Picking the first *unmuted*
        // track also survives the unmute-creates-a-new-source-name case, where the stale
        // muted track can still sit ahead of the live one in `snapshot.tracks`.
        //
        // Merged mode lets a live share take this canvas over the camera; split mode leaves
        // the camera here and puts the share in its own canvas (see `syncRemoteParticipants`).
        let live = liveVideoTracks(for: participant)
        let picked = mergesRemoteScreenShareWithCamera
            ? (live.first { $0.videoType == .desktop } ?? live.first)
            : live.first { $0.videoType != .desktop }
        // Stopping a share makes the far end drop every unmuted video track for ~10-20 s while
        // it re-acquires the camera (the device log shows the camera coming back muted, then
        // unmuting). Hold the track on screen for that window instead of flashing the avatar:
        // the surface stays bound to the same stream, so the last share frame stays frozen and
        // the camera frames resume without a rebind. Capped so a real camera-off still ends on
        // the avatar.
        var videoID = picked?.id
        if videoID == nil {
            let since = holdSince[participant.id] ?? Date()
            holdSince[participant.id] = since
            // Keep the track that is already on screen: switching to the muted camera would
            // reset the surface and show black, because that track produces no frames yet.
            if Date().timeIntervalSince(since) < Self.videoHoldLimit {
                videoID = conference?.remoteTracks.values
                    .first {
                        $0.owner == participant.id
                        && $0.mediaType == .video
                        && $0.snapshot.videoType != .desktop
                    }?
                    .id
                ?? canvasModels[participant.id]?.participant?.videoTrackID
            }
        } else {
            holdSince[participant.id] = nil
        }
        logCanvasSelection(participant, live: live, chosen: videoID)
        let level = participantAudioLevels[participant.id] ?? 0
        return CanvasParticipant(
            id: participant.id,
            displayName: participant.displayName,
            avatarURL: participant.snapshot.avatarURL,
            videoTrackID: videoID,
            audioMuted: participant.isAudioMuted,
            audioLevel: level,
            isSpeaking: level >= Self.speakingThreshold && !participant.isAudioMuted,
            raisedHand: participant.raisedHand,
            connectionQualityLevel: participantQualityLevels[participant.id]
        )
    }

    private func discardRemoteCanvases(notify: Bool) {
        let ids = Array(canvasModels.keys)
        canvasModels.removeAll()
        canvasHosts.removeAll()
        if notify {
            for id in ids { canvasStyleOverrides[id] = nil }
        }
        knownParticipantMedia.removeAll()
        for mediaType in muteBatchTasks.keys { muteBatchTasks[mediaType]?.cancel() }
        muteBatchTasks.removeAll()
        muteBatchWindow.removeAll()
        guard notify else { return }
        for id in ids {
            delegate?.jitsiDidLeaveRemoteParticipant?(id)
        }
    }

    /// Several remotes muting inside one window is how jitsi-meet's "Mute everyone" reaches
    /// the clients; lib-jitsi-meet has no room-level event and no actor, so this is a
    /// heuristic. Per-participant changes remain exact through the delegate methods above.
    private func noteRemoteMute(_ id: String, _ mediaType: MediaType) {
        muteBatchWindow[mediaType, default: []].insert(id)
        guard muteBatchTasks[mediaType] == nil else { return }
        muteBatchTasks[mediaType] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.muteBatchWindowNanos)
            guard !Task.isCancelled else { return }
            self?.flushMuteBatch(mediaType)
        }
    }

    private func flushMuteBatch(_ mediaType: MediaType) {
        muteBatchTasks[mediaType] = nil
        let ids = muteBatchWindow[mediaType] ?? []
        muteBatchWindow[mediaType] = nil
        guard ids.count >= Self.muteBatchMinimumParticipants else { return }
        delegate?.jitsiDidMuteAllRemotes?(mediaType.rawValue, participantIDs: ids.sorted())
    }

    // MARK: - Meeting timing

    private struct TimeRestrictedLimit {
        let duration: TimeInterval
        let elapsed: TimeInterval
    }

    /// `mod_time_restricted` payload sent as the room: `{type, durationSeconds, elapsedSeconds}`.
    private static func parseTimeRestricted(_ text: String) -> TimeRestrictedLimit? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "time_restricted",
              let duration = (object["durationSeconds"] as? NSNumber)?.doubleValue,
              duration > 0
        else { return nil }
        let elapsed = (object["elapsedSeconds"] as? NSNumber)?.doubleValue ?? 0
        return TimeRestrictedLimit(duration: duration, elapsed: max(0, elapsed))
    }

    private func recomputeMeetingTiming() {
        guard let joinedAt = localJoinedAt else { return }
        let start: Date
        let source: MeetingTiming.StartSource
        if let serverCreatedAt {
            start = serverCreatedAt
            source = .serverCreated
        } else if let restrictedLimit {
            start = restrictedLimit.startedAt
            source = .serverRestricted
        } else {
            start = joinedAt
            source = .localJoin
        }

        let limit: (value: TimeInterval, source: MeetingTiming.LimitSource, start: Date)?
        if let restrictedLimit {
            limit = (restrictedLimit.duration, .serverEnforced, restrictedLimit.startedAt)
        } else if meetingTimeLimit > 0 {
            limit = (meetingTimeLimit, .hostConfigured, start)
        } else {
            limit = nil
        }

        meetingTiming = MeetingTiming(
            startedAt: start,
            startSource: source,
            timeLimit: limit?.value,
            limitSource: limit?.source,
            limitStartedAt: limit?.start,
            capturedAt: Date()
        )
    }

    private var hasCompleteTimingSources: Bool {
        serverCreatedAt != nil && (restrictedLimit != nil || meetingTimeLimit > 0)
    }

    /// Fires `jitsiDidJoinMeetingTiming:` once. Complete sources deliver at once; otherwise
    /// the join handshake gets two seconds before the snapshot is taken as-is.
    private func scheduleMeetingTimingDelivery() {
        guard !hasDeliveredMeetingTiming, localJoinedAt != nil else { return }
        if hasCompleteTimingSources {
            deliverMeetingTiming()
            return
        }
        guard timingDeliveryTask == nil else { return }
        timingDeliveryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.timingDeliveryTask = nil
            self?.deliverMeetingTiming()
        }
    }

    private func deliverMeetingTiming() {
        guard !hasDeliveredMeetingTiming, hasJoined else { return }
        timingDeliveryTask?.cancel()
        timingDeliveryTask = nil
        recomputeMeetingTiming()
        guard let timing = meetingTiming else { return }
        hasDeliveredMeetingTiming = true
        delegate?.jitsiDidJoinMeetingTiming?(JitsiMeetingTiming(timing: timing))
    }

    private func resetMeetingTiming() {
        timingDeliveryTask?.cancel()
        timingDeliveryTask = nil
        hasDeliveredMeetingTiming = false
        serverCreatedAt = nil
        restrictedLimit = nil
        localJoinedAt = nil
        meetingTiming = nil
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
            "isPreviewing": isPreviewing,
            "isAudioMuted": isAudioMuted,
            "isVideoMuted": isVideoMuted,
            "isScreenSharing": isScreenSharing,
            "isLocked": isLocked,
            "e2eeEnabled": conference?.e2eeEnabled ?? false,
            "visitorsSupported": conference?.visitorsSupported ?? false,
            "participants": participants(),
            "localAudioLevel": participantAudioLevels["local"] ?? 0,
            "localIsSpeaking": {
                let level = participantAudioLevels["local"] ?? 0
                return level >= Self.speakingThreshold && !isAudioMuted
            }(),
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
        if let audioOutputRoute {
            snapshot["audioOutputRoute"] = audioOutputRoute
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

/// Live state behind one ObjC-hosted canvas view.
@MainActor
private final class CanvasModel: ObservableObject {
    @Published var participant: CanvasParticipant?
    /// Per-canvas appearance; `JitsiSDK.setCanvasStyle(_:forParticipant:)` writes here too.
    @Published var style = ParticipantCanvasStyle()
    /// Only the self-view uses this: the front camera is mirrored, the rear one is not.
    @Published var mirrored = true

    func frames(for trackID: TrackID) -> AsyncStream<VideoPixelFrame> {
        JitsiMeet.shared.engine?.frameStream(for: trackID) ?? AsyncStream { $0.finish() }
    }
}

/// Hosts the same canvas the SwiftUI API uses, driven by a plain model instead of a session.
private struct RemoteCanvasHost: View {
    @ObservedObject var model: CanvasModel

    var body: some View {
        ParticipantCanvasContent(
            participant: model.participant,
            isLocal: false,
            style: model.style,
            frames: model.frames(for:)
        )
    }
}

/// Self-view host: identical renderer, local mirroring follows the active camera.
private struct LocalCanvasHost: View {
    @ObservedObject var model: CanvasModel

    var body: some View {
        ParticipantCanvasContent(
            participant: model.participant,
            isLocal: true,
            mirrored: model.mirrored,
            style: model.style,
            frames: model.frames(for:)
        )
    }
}

private extension JitsiCanvasStyle {
    var participantStyle: ParticipantCanvasStyle {
        ParticipantCanvasStyle(
            videoFillMode: fillMode == .fit ? .fit : .fill,
            cornerRadius: cornerRadius,
            avatarSize: avatarSize,
            showsName: showsName,
            showsMicrophoneBadge: showsMicrophoneBadge,
            showsConnectionBadge: showsConnectionBadge,
            avatarPlacement: CanvasOverlayPlacement(rawValue: avatarPosition) ?? .center,
            namePlacement: CanvasOverlayPlacement(rawValue: namePosition) ?? .bottomLeading,
            nameFontSize: nameFontSize,
            showsAvatar: showsAvatar,
            showsAudioLevel: showsAudioLevel
        )
    }
}

/// Meeting clock snapshot handed to the ObjC delegate.
///
/// `elapsedSecondsAtJoin` is fixed at capture time; tick a label from `startedAt` with a
/// timer, or call `JitsiSDK.meetingElapsedSeconds` / `meetingRemainingSeconds`.
@objcMembers
public final class JitsiMeetingTiming: NSObject {
    public let startedAt: Date
    public let elapsedSecondsAtJoin: TimeInterval
    /// Nil when the deployment enforces no limit and the host configured none.
    public let timeLimitSeconds: NSNumber?
    /// `"serverCreated"`, `"serverRestricted"` or `"localJoin"`.
    public let startSource: String
    /// `"serverEnforced"`, `"hostConfigured"`, or nil when unlimited/unknown.
    public let limitSource: String?

    init(timing: MeetingTiming) {
        startedAt = timing.startedAt
        elapsedSecondsAtJoin = timing.elapsed
        timeLimitSeconds = timing.timeLimit.map { NSNumber(value: $0) }
        startSource = timing.startSource.rawValue
        limitSource = timing.limitSource?.rawValue
        super.init()
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

    /// Per-participant microphone level, 0...1, about five times a second while anyone
    /// speaks. Keys are MUC participant ids, plus `"local"` for this endpoint. Delivered
    /// on the main queue and never triggers `jitsiDidChangeState:`.
    @objc optional func jitsiDidUpdateAudioLevels(_ levels: [String: Double])

    /// The system output moved (Bluetooth connected, headphones unplugged…). `route` is
    /// where audio plays now: `receiver`, `speaker`, `headphones`, `bluetooth` or `carPlay`.
    @objc optional func jitsiDidChangeAudioOutputRoute(_ route: String)

    /// A remote participant became renderable. Add the view to a tile and lay it out freely;
    /// it keeps following the meeting. The local participant never appears here.
    @objc optional func jitsiDidJoinRemoteCanvas(
        _ canvasView: UIView,
        participantID: String,
        displayName: String
    )

    /// A remote canvas participant left, including every remaining remote on hang-up.
    @objc optional func jitsiDidLeaveRemoteParticipant(_ participantID: String)

    /// A remote participant toggled its microphone. Change-only: the initial state comes
    /// with the canvas.
    @objc optional func jitsiRemoteParticipant(
        _ participantID: String,
        didChangeMicrophoneMuted muted: Bool
    )

    /// A remote participant toggled its camera. Change-only, like the microphone callback.
    @objc optional func jitsiRemoteParticipant(
        _ participantID: String,
        didChangeCameraMuted muted: Bool
    )

    /// The room-wide AV moderation switch changed. `mediaType` is `"audio"`, `"video"` or
    /// `"desktop"`; enabling it force-mutes and blocks self-unmute.
    @objc optional func jitsiDidChangeAVModeration(
        _ mediaType: String,
        enabled: Bool,
        actorID: String?
    )

    /// Several remotes muted inside one short window — how the host's "mute everyone" reaches
    /// the clients. Heuristic, since the lib has no room-level event; use the per-participant
    /// callbacks for exact facts.
    @objc optional func jitsiDidMuteAllRemotes(_ mediaType: String, participantIDs: [String])

    /// Fires once after joining with the meeting's start anchor and time limit. A source that
    /// arrives later refreshes `JitsiSDK.meetingTiming` without a second callback.
    @objc optional func jitsiDidJoinMeetingTiming(_ timing: JitsiMeetingTiming)

    /// A local recording finished. `fileURL` is nil when it failed; the stop completion
    /// receives the same result.
    @objc optional func jitsiDidFinishLocalRecording(_ fileURL: NSURL?, error: NSError?)
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
        case .audioOutputRouteChanged: return "audioOutputRouteChanged"
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
        case .nonParticipantMessage: return "nonParticipantMessage"
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
        case .audioOutputRouteChanged(let route):
            return ["route": route.rawValue]
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
        case .nonParticipantMessage(let from, let text):
            return ["from": from ?? NSNull(), "text": text]
        case .audioLevels(let levels):
            return levels.mapValues { $0 as Any }
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
