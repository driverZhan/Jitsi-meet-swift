#if canImport(WebRTC)
import Accelerate
import AVFoundation
import CoreMedia
import Foundation
import JitsiCore
import os
#if canImport(UIKit)
import UIKit
#endif
import WebRTC

/// `MediaBackend` on the libwebrtc ObjC API.
///
/// This is the only file in the skeleton that talks to libwebrtc. Its whole job is to
/// keep two things portable across the JS boundary: SDP as raw strings (so
/// lib-jitsi-meet's munging keeps working) and video frames as `CVPixelBuffer` (so the
/// UI never renders inside a browser process).
///
/// Selector spellings were verified against the vendored JitsiWebRTC 124.0.2 headers; README
/// section 8 is the checklist to re-run when `Frameworks/WebRTC.xcframework` changes.
public final class WebRTCBackend: MediaBackend {
    public let capabilities: MediaCapabilities

    private let factory: RTCPeerConnectionFactory
    private let discovery = CaptureCoordinator()
    private let pipeline = CapturePipeline()
    private let frames = FrameHub()
    private static let audioLog = Logger(subsystem: "org.jitsi.sdk", category: "audio")

    private let lock = NSLock()
    private var localTracks: [TrackID: RTCMediaStreamTrack] = [:]
    private var remoteTracks: [TrackID: RTCVideoTrack] = [:]
    private var peers: [String: WebRTCPeer] = [:]
    private var screenTrack: ScreenTrack?
    private var screenFormatConfigured = false
    /// Created on first activation; `AudioSessionManager` is main-actor isolated.
    private var audioSession: AudioSessionManager?
    /// Non-nil only when `useCustomAudioDevice` was set at install time. Retained here
    /// because libwebrtc does not guarantee ownership of the injected device.
    private let customAudioDevice: VoiceProcessingAudioDevice?
    /// App-level route observer, forwarded from the session's notifications.
    private var audioRouteObserver: ((AudioOutputRoute) -> Void)?

    private struct ScreenTrack {
        let track: RTCVideoTrack
        let source: RTCVideoSource
        let capturer: RTCVideoCapturer
        let receiver: ScreenShareReceiver
    }

    /// libwebrtc's sources are not retained by the tracks they feed.
    private var sources: [TrackID: AnyObject] = [:]

    public init(capabilities: MediaCapabilities, useCustomAudioDevice: Bool = false) {
        self.capabilities = capabilities
        _ = Self.nativeLogBridge
        let encoderFactory = RTCDefaultVideoEncoderFactory()
        let decoderFactory = RTCDefaultVideoDecoderFactory()
        if useCustomAudioDevice {
            let device = VoiceProcessingAudioDevice()
            customAudioDevice = device
            factory = RTCPeerConnectionFactory(
                encoderFactory: encoderFactory,
                decoderFactory: decoderFactory,
                audioDevice: device
            )
        } else {
            customAudioDevice = nil
            factory = RTCPeerConnectionFactory(
                encoderFactory: encoderFactory,
                decoderFactory: decoderFactory
            )
        }
    }

    /// libwebrtc has no default log sink on iOS; without this, a rejected configuration only
    /// surfaces as a nil peer connection. Debug builds forward errors so Xcode shows the cause.
    private static let nativeLogBridge: RTCCallbackLogger = {
        let logger = RTCCallbackLogger()
        #if DEBUG
        logger.severity = .error
        logger.start { message in
            NSLog("[webrtc] %@", message)
        }
        #endif
        return logger
    }()

    public func prepare() async throws {
        // The injected device owns `AVAudioSession` end to end, so `RTCAudioSession` (the
        // wrapper for libwebrtc's own audio unit) has nothing to gate here.
        guard customAudioDevice == nil else { return }
        // `AudioSessionManager` owns AVAudioSession (category, route, interruptions), so
        // WebRTC's audio session wrapper must not activate the session itself. Manual audio
        // is that switch. `isAudioEnabled` is deliberately NOT set here: it starts the VoIP
        // audio unit the moment it flips, and doing that before the session is active leaves
        // a unit that never records or plays.
        RTCAudioSession.sharedInstance().useManualAudio = true
    }

    public func activateAudioSession(preferSpeaker: Bool) async throws {
        if let customAudioDevice {
            try await MainActor.run {
                let manager = audioSession ?? AudioSessionManager()
                self.audioSession = manager
                manager.onRouteChange = { [weak self] route in
                    self?.notifyAudioRoute(AudioOutputRoute(route))
                }
                try customAudioDevice.activate(preferSpeaker: preferSpeaker)
                manager.refreshCurrentRoute()
                // Hand out the starting route; the notification only covers later moves.
                self.notifyAudioRoute(AudioOutputRoute(manager.currentRoute))
            }
            return
        }
        try await MainActor.run {
            let manager = audioSession ?? AudioSessionManager()
            self.audioSession = manager
            manager.onRouteChange = { [weak self] route in
                self?.notifyAudioRoute(AudioOutputRoute(route))
            }
            try manager.beginConference(preferSpeaker: preferSpeaker)
            // Hand out the starting route; the notification only covers later moves.
            self.notifyAudioRoute(AudioOutputRoute(manager.currentRoute))
        }
        // Manual audio means RTCAudioSession never sees the activation that happened above.
        // Telling it explicitly is what allows the audio unit to start; without this the
        // conference is technically connected while both directions carry silence.
        let rtcSession = RTCAudioSession.sharedInstance()
        rtcSession.audioSessionDidActivate(AVAudioSession.sharedInstance())
        rtcSession.isAudioEnabled = true
        #if DEBUG
        let session = AVAudioSession.sharedInstance()
        Self.audioLog.notice("active category=\(session.category.rawValue, privacy: .public) mode=\(session.mode.rawValue, privacy: .public) options=\(session.categoryOptions.rawValue) route=\(session.currentRoute.outputs.first?.portType.rawValue ?? "none", privacy: .public)")
        #endif
    }

    public func deactivateAudioSession() async {
        if let customAudioDevice {
            customAudioDevice.deactivate()
            await MainActor.run {
                self.audioSession?.onRouteChange = nil
            }
            return
        }
        let rtcSession = RTCAudioSession.sharedInstance()
        rtcSession.isAudioEnabled = false
        rtcSession.audioSessionDidDeactivate(AVAudioSession.sharedInstance())
        await MainActor.run {
            // No route events between conferences; activation re-attaches the handler.
            self.audioSession?.onRouteChange = nil
            try? self.audioSession?.endConference()
        }
    }

    public func audioOutput() async throws -> AudioOutputRoute {
        try await MainActor.run {
            guard let manager = audioSession else {
                throw JitsiError.notConnected
            }
            return AudioOutputRoute(manager.currentRoute)
        }
    }

    public func setAudioOutput(_ route: AudioOutputRoute) async throws {
        guard route.isBuiltIn else {
            throw JitsiError.invalidArgument(
                "audio route must be receiver or speaker; \(route.rawValue) is chosen by the system while connected")
        }
        try await MainActor.run {
            guard let manager = audioSession else {
                throw JitsiError.notConnected
            }
            if let customAudioDevice {
                try customAudioDevice.setSpeaker(route == .speaker)
                manager.refreshCurrentRoute()
            } else {
                try manager.preferSpeaker(route == .speaker)
            }
        }
    }

    public func setAudioOutputObserver(_ handler: ((AudioOutputRoute) -> Void)?) {
        lock.lock()
        audioRouteObserver = handler
        lock.unlock()
    }

    private func notifyAudioRoute(_ route: AudioOutputRoute) {
        lock.lock()
        let observer = audioRouteObserver
        lock.unlock()
        observer?(route)
    }

    public func shutdown() async {
        await pipeline.stop()
        lock.lock()
        let live = Array(peers.values)
        let screen = screenTrack
        screenTrack = nil
        peers.removeAll()
        localTracks.removeAll()
        remoteTracks.removeAll()
        sources.removeAll()
        lock.unlock()
        screen?.receiver.stop()
        for peer in live {
            peer.close()
        }
    }

    public func enumerateDevices() async throws -> [DeviceDescriptor] {
        discovery.enumerate()
    }

    public func requestAccess(for mediaTypes: [MediaType]) async -> [MediaType: Bool] {
        await discovery.requestAccess(for: mediaTypes)
    }

    public func startCapture(
        _ mediaTypes: [MediaType],
        deviceIDs: [String: String]
    ) async throws -> [TrackSnapshot] {
        var snapshots: [TrackSnapshot] = []
        for mediaType in mediaTypes {
            let deviceID = deviceIDs[mediaType == .audio ? "audio" : "video"]
            let trackID = UUID().uuidString
            let created: TrackSnapshot
            switch mediaType {
            case .audio:
                let source = factory.audioSource(with: nil)
                let track = factory.audioTrack(with: source, trackId: trackID)
                retain(source, for: track.trackId)
                created = snapshot(for: track, mediaType: .audio, deviceID: deviceID, label: "Microphone")
            case .video:
                let source = factory.videoSource()
                let track = factory.videoTrack(with: source, trackId: trackID)
                // Key everything by the id libwebrtc actually assigned. The id handed to the
                // factory is a request, not a guarantee, and `TrackSnapshot.id` (what the UI
                // subscribes with) comes from `track.trackId`.
                retain(source, for: track.trackId)
                track.add(frames.renderer(for: track.trackId))
                pipeline.setVideoSource(source, deviceID: deviceID)
                created = snapshot(for: track, mediaType: .video, deviceID: deviceID, label: "Camera")
            }
            snapshots.append(created)
        }
        await pipeline.startIfNeeded()
        return snapshots
    }

    private func retain(_ source: AnyObject, for trackID: TrackID) {
        lock.lock()
        sources[trackID] = source
        lock.unlock()
    }

    public func stopCapture(_ trackIDs: [TrackID]) async {
        lock.lock()
        var stoppedScreen: ScreenTrack?
        if let screen = screenTrack, trackIDs.contains(screen.track.trackId) {
            stoppedScreen = screen
            screenTrack = nil
            screenFormatConfigured = false
        }
        let doomed = trackIDs.compactMap { id -> RTCMediaStreamTrack? in
            sources[id] = nil
            guard let track = localTracks.removeValue(forKey: id) else {
                remoteTracks.removeValue(forKey: id)
                return nil
            }
            return track
        }
        let videoStillLive = localTracks.values.contains { $0.kind == "video" }
        lock.unlock()
        stoppedScreen?.receiver.stop()
        frames.clear(trackIDs)
        for track in doomed {
            // libwebrtc has no `stop` on a track; disabling it is how a track ends.
            track.isEnabled = false
        }
        if !videoStillLive {
            pipeline.setVideoSource(nil, deviceID: nil)
            await pipeline.stopIfIdle()
        }
    }

    public func startScreenShare() async throws -> TrackSnapshot {
        lock.lock()
        if let existing = screenTrack {
            lock.unlock()
            return TrackSnapshot(
                id: existing.track.trackId,
                mediaType: .video,
                isLocal: true,
                muted: false,
                videoType: .desktop,
                deviceID: "screen",
                label: "Screen"
            )
        }
        lock.unlock()

        let source = factory.videoSource(forScreenCast: true)
        let capturer = RTCVideoCapturer(delegate: source)
        let track = factory.videoTrack(with: source, trackId: UUID().uuidString)
        let receiver = ScreenShareReceiver()
        try receiver.start { [weak self] frame in
            self?.renderScreenFrame(frame, source: source, capturer: capturer)
        }

        let screen = ScreenTrack(track: track, source: source, capturer: capturer, receiver: receiver)
        lock.lock()
        screenTrack = screen
        screenFormatConfigured = false
        localTracks[track.trackId] = track
        sources[track.trackId] = source
        lock.unlock()
        // The local preview can render the same frames the conference sends.
        track.add(frames.renderer(for: track.trackId))

        return TrackSnapshot(
            id: track.trackId,
            mediaType: .video,
            isLocal: true,
            muted: false,
            videoType: .desktop,
            deviceID: "screen",
            label: "Screen"
        )
    }

    public func stopScreenShare() async {
        lock.lock()
        let id = screenTrack?.track.trackId
        lock.unlock()
        guard let id else { return }
        await stopCapture([id])
    }

    /// The extension sends device-native buffers, so the only rotation work left is mapping
    /// the wire value; `adaptOutputFormat` tells libwebrtc the source dimensions the first
    /// time a frame arrives.
    private func renderScreenFrame(_ frame: ScreenShareFrame, source: RTCVideoSource, capturer: RTCVideoCapturer) {
        let width = Int32(CVPixelBufferGetWidth(frame.pixelBuffer))
        let height = Int32(CVPixelBufferGetHeight(frame.pixelBuffer))
        lock.lock()
        let needsFormat = !screenFormatConfigured
        screenFormatConfigured = true
        lock.unlock()
        if needsFormat {
            source.adaptOutputFormat(toWidth: width, height: height, fps: 5)
        }
        let rtcFrame = RTCVideoFrame(
            buffer: RTCCVPixelBuffer(pixelBuffer: frame.pixelBuffer),
            rotation: Self.rtcRotation(frame.rotation),
            timeStampNs: frame.timestampUs * 1000
        )
        source.capturer(capturer, didCapture: rtcFrame)
    }

    private static func rtcRotation(_ rotation: VideoRotation) -> RTCVideoRotation {
        switch rotation {
        case .none: return ._0
        case .clockwise: return ._90
        case .upsideDown: return ._180
        case .counterClockwise: return ._270
        }
    }

    public func switchCamera() async throws -> String {
        try await pipeline.switchCamera()
    }

    public func videoCapabilities(for trackID: TrackID) async throws -> VideoTrackCapabilities {
        try ensureCameraTrack(trackID)
        return try await pipeline.videoCapabilities()
    }

    public func applyVideoConstraints(
        _ constraints: VideoConstraints,
        for trackID: TrackID
    ) async throws -> VideoTrackCapabilities {
        try ensureCameraTrack(trackID)
        return try await pipeline.applyVideoConstraints(constraints)
    }

    /// Screen-share and remote tracks have no camera formats; only the live capture track
    /// may be inspected or reconfigured.
    private func ensureCameraTrack(_ trackID: TrackID) throws {
        lock.lock()
        let track = localTracks[trackID]
        let isScreen = screenTrack?.track.trackId == trackID
        lock.unlock()
        guard let track, track.kind == "video", !isScreen else {
            throw JitsiError.noLocalTrack(.video)
        }
    }

    public func setTrackMuted(_ trackID: TrackID, muted: Bool) async throws {
        guard let track = track(for: trackID) else {
            throw JitsiError.noLocalTrack(.audio)
        }
        track.isEnabled = !muted
    }

    public func frameStream(for trackID: TrackID) -> AsyncStream<VideoPixelFrame> {
        frames.stream(for: trackID)
    }

    public func makePeerConnection(
        _ config: PeerConnectionConfig,
        onEvent: @escaping @Sendable (PeerEvent) -> Void
    ) -> PeerConnectionHandle? {
        let rtcConfig = RTCConfiguration()
        rtcConfig.iceServers = config.iceServers.map { server in
            RTCIceServer(urlStrings: server.urls, username: server.username, credential: server.credential)
        }
        rtcConfig.sdpSemantics = .unifiedPlan
        rtcConfig.continualGatheringPolicy = .gatherContinually
        rtcConfig.tcpCandidatePolicy = .enabled
        rtcConfig.bundlePolicy = .maxBundle
        rtcConfig.rtcpMuxPolicy = .require

        guard let connection = factory.peerConnection(
            with: rtcConfig,
            constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil),
            delegate: nil
        ) else {
            NSLog("[jitsi-media] libwebrtc rejected the peer connection; check ICE server URLs")
            return nil
        }
        let peer = WebRTCPeer(
            connection: connection,
            simulcast: config.enableSimulcast,
            onEvent: onEvent,
            backend: self
        )
        lock.lock()
        peers[peer.id] = peer
        lock.unlock()
        return peer
    }

    // MARK: - Track plumbing

    func track(for trackID: TrackID) -> RTCMediaStreamTrack? {
        lock.lock()
        defer { lock.unlock() }
        return localTracks[trackID] ?? remoteTracks[trackID]
    }

    func videoTrack(for trackID: TrackID) -> RTCVideoTrack? {
        lock.lock()
        defer { lock.unlock() }
        return (localTracks[trackID] as? RTCVideoTrack) ?? remoteTracks[trackID]
    }

    func registerRemote(_ track: RTCVideoTrack, snapshot: TrackSnapshot) {
        lock.lock()
        remoteTracks[snapshot.id] = track
        lock.unlock()
        track.add(frames.renderer(for: snapshot.id))
    }

    func forgetPeer(_ id: String) {
        lock.lock()
        peers[id] = nil
        lock.unlock()
    }

    private func snapshot(
        for track: RTCMediaStreamTrack,
        mediaType: MediaType,
        deviceID: String?,
        label: String
    ) -> TrackSnapshot {
        lock.lock()
        localTracks[track.trackId] = track
        lock.unlock()
        return TrackSnapshot(
            id: track.trackId,
            mediaType: mediaType,
            isLocal: true,
            muted: !track.isEnabled,
            videoType: mediaType == .video ? .camera : .noVideo,
            deviceID: deviceID,
            label: label
        )
    }
}

/// Fan-out from libwebrtc renderers to Swift `AsyncStream`s consumed by the UI.
private final class FrameHub {
    private let lock = NSLock()
    private var sinks: [TrackID: [UUID: (VideoPixelFrame) -> Void]] = [:]

    func stream(for trackID: TrackID) -> AsyncStream<VideoPixelFrame> {
        let token = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            self.lock.lock()
            var perTrack = self.sinks[trackID] ?? [:]
            perTrack[token] = { continuation.yield($0) }
            self.sinks[trackID] = perTrack
            self.lock.unlock()
            continuation.onTermination = { _ in
                self.lock.lock()
                self.sinks[trackID]?[token] = nil
                self.lock.unlock()
            }
        }
    }

    func clear(_ trackIDs: [TrackID]) {
        lock.lock()
        for id in trackIDs {
            sinks[id] = nil
        }
        lock.unlock()
    }

    func renderer(for trackID: TrackID) -> RTCVideoRenderer {
        PixelBufferRenderer(trackID: trackID, hub: self)
    }

    func deliver(_ frame: VideoPixelFrame, to trackID: TrackID) {
        lock.lock()
        let listeners = Array(sinks[trackID]?.values ?? [:].values)
        lock.unlock()
        for listener in listeners {
            listener(frame)
        }
    }
}

/// Adapts libwebrtc's `RTCVideoRenderer` to `CVPixelBuffer` frames.
private final class PixelBufferRenderer: NSObject, RTCVideoRenderer {
    private let trackID: TrackID
    private let hub: FrameHub

    init(trackID: TrackID, hub: FrameHub) {
        self.trackID = trackID
        self.hub = hub
    }

    /// The UI layer sizes itself from the pixel buffer, so the advertised size is not used.
    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame, let pixelBuffer = Self.pixelBuffer(from: frame.buffer) else { return }
        hub.deliver(
            VideoPixelFrame(
                pixelBuffer: pixelBuffer,
                timestampUs: Int64(frame.timeStampNs / 1000),
                rotation: Self.rotation(frame.rotation)
            ),
            to: trackID
        )
    }

    /// Local capture hands over CoreVideo buffers, but libwebrtc's software decoders
    /// (VP8/VP9, which is what Jitsi negotiates by default) produce I420, and the display
    /// layer only accepts `CVPixelBuffer`. Without this conversion remote video silently
    /// disappears.
    private static func pixelBuffer(from buffer: RTCVideoFrameBuffer) -> CVPixelBuffer? {
        if let cvBuffer = buffer as? RTCCVPixelBuffer {
            return cvBuffer.pixelBuffer
        }
        return argbPixelBuffer(fromI420: buffer.toI420())
    }

    /// WebRTC's I420 is video-range BT.601, which is exactly what this conversion is set up for.
    private static let ypCbCrInfo: vImage_YpCbCrToARGB = {
        var info = vImage_YpCbCrToARGB()
        var range = vImage_YpCbCrPixelRange(
            Yp_bias: 16, CbCr_bias: 128,
            YpRangeMax: 235, CbCrRangeMax: 240,
            YpMax: 255, YpMin: 0, CbCrMax: 255, CbCrMin: 0
        )
        vImageConvert_YpCbCrToARGB_GenerateConversion(
            kvImage_YpCbCrToARGBMatrix_ITU_R_601_4, &range, &info,
            kvImage420Yp8_Cb8_Cr8, kvImageARGB8888, vImage_Flags(kvImageNoFlags)
        )
        return info
    }()

    private static func argbPixelBuffer(fromI420 source: any RTCI420BufferProtocol) -> CVPixelBuffer? {
        let width = Int(source.width)
        let height = Int(source.height)
        guard width > 0, height > 0 else { return nil }

        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferCGImageCompatibilityKey: true
        ]
        var destination: CVPixelBuffer?
        // BGRA, not ARGB: `AVSampleBufferDisplayLayer` only reliably consumes the byte-order
        // formats CoreVideo defines for display, and the vImage permute below swaps R/B.
        guard CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            attributes as CFDictionary, &destination
        ) == kCVReturnSuccess, let pixelBuffer = destination else {
            return nil
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }

        var y = vImage_Buffer(
            data: UnsafeMutableRawPointer(mutating: source.dataY),
            height: vImagePixelCount(height), width: vImagePixelCount(width),
            rowBytes: Int(source.strideY)
        )
        var u = vImage_Buffer(
            data: UnsafeMutableRawPointer(mutating: source.dataU),
            height: vImagePixelCount(source.chromaHeight), width: vImagePixelCount(source.chromaWidth),
            rowBytes: Int(source.strideU)
        )
        var v = vImage_Buffer(
            data: UnsafeMutableRawPointer(mutating: source.dataV),
            height: vImagePixelCount(source.chromaHeight), width: vImagePixelCount(source.chromaWidth),
            rowBytes: Int(source.strideV)
        )
        var out = vImage_Buffer(
            data: base,
            height: vImagePixelCount(height), width: vImagePixelCount(width),
            rowBytes: CVPixelBufferGetBytesPerRow(pixelBuffer)
        )
        var info = ypCbCrInfo
        // vImage emits ARGB by default; reversing the channel map writes BGRA in place.
        var permute: [UInt8] = [3, 2, 1, 0]
        let error = vImageConvert_420Yp8_Cb8_Cr8ToARGB8888(
            &y, &u, &v, &out, &info, permute, 255, vImage_Flags(kvImageNoFlags)
        )
        return error == kvImageNoError ? pixelBuffer : nil
    }

    private static func rotation(_ rotation: RTCVideoRotation) -> VideoRotation {
        switch rotation {
        case ._0: return .none
        case ._90: return .clockwise
        case ._180: return .upsideDown
        case ._270: return .counterClockwise
        @unknown default: return .none
        }
    }
}

/// One libwebrtc peer connection behind the synchronous `PeerConnectionHandle` shape.
private final class WebRTCPeer: NSObject, PeerConnectionHandle, RTCPeerConnectionDelegate, RTCDataChannelDelegate {
    let id: String
    private let connection: RTCPeerConnection
    private let simulcast: Bool
    private let onEvent: (PeerEvent) -> Void
    private weak var backend: WebRTCBackend?
    private var channels: [String: RTCDataChannel] = [:]
    /// Channel ids that already reported "open" to the JS shim. `didOpen` and
    /// `didChangeState(.open)` can both fire for one channel; the JS side treats a second
    /// open as a real event (lib-jitsi-meet re-runs its onopen handler), so emit once.
    private var openedChannelIDs = Set<Int32>()
    private let semaphore = DispatchSemaphore(value: 1)

    init(
        connection: RTCPeerConnection,
        simulcast: Bool,
        onEvent: @escaping @Sendable (PeerEvent) -> Void,
        backend: WebRTCBackend
    ) {
        id = UUID().uuidString
        self.connection = connection
        self.simulcast = simulcast
        self.onEvent = onEvent
        self.backend = backend
        super.init()
        connection.delegate = self
    }

    // MARK: Synchronous surface

    @discardableResult
    func addTrack(_ trackID: TrackID, streamID: String, capture _: Bool) -> String? {
        guard let track = backend?.track(for: trackID) else {
            NSLog("[jitsi-media] addTrack(\(trackID)) ignored: backend does not own this track")
            return nil
        }
        return connection.add(track, streamIds: [streamID])?.senderId
    }

    func removeTrack(_ trackID: TrackID) {
        for sender in connection.senders where sender.track?.trackId == trackID {
            connection.removeTrack(sender)
        }
    }

    func replaceTrack(senderID: String?, oldTrackID: TrackID?, trackID: TrackID?, kind: String?) {
        let track = trackID.flatMap { backend?.track(for: $0) }
        if trackID != nil, track == nil {
            NSLog("[jitsi-media] replaceTrack(\(trackID!)) ignored: backend does not own this track")
            return
        }
        let sender = senderID.flatMap { id in
            connection.senders.first { $0.senderId == id }
        } ?? oldTrackID.flatMap { id in
            connection.senders.first { $0.track?.trackId == id }
        } ?? senderForKind(kind)
        guard let sender else {
            NSLog("[jitsi-media] replaceTrack(\(trackID ?? "nil")) found no sender")
            return
        }
        sender.track = track
    }

    /// A transceiver created from a remote m-line has a native sender with no track yet;
    /// lib-jitsi-meet attaches the first local track through that sender.
    private func senderForKind(_ kind: String?) -> RTCRtpSender? {
        let mediaType: RTCRtpMediaType
        switch kind {
        case "audio":
            mediaType = .audio
        case "video":
            mediaType = .video
        default:
            return nil
        }
        let candidates = connection.transceivers.filter { $0.mediaType == mediaType }
        return (candidates.first { $0.sender.track == nil } ?? candidates.first)?.sender
    }

    func openDataChannel(label: String, kind _: DataChannelKind) {
        // `kind` makes no difference here: libwebrtc only offers one reliable, ordered
        // string channel, and Jitsi's colibri channel is a WebSocket, not a data channel.
        let config = RTCDataChannelConfiguration()
        config.isOrdered = true
        let channel = connection.dataChannel(forLabel: label, configuration: config)
        channel?.delegate = self
        channels[label] = channel
    }

    func send(_ text: String, onChannel label: String) {
        let buffer = RTCDataBuffer(data: Data(text.utf8), isBinary: false)
        channels[label]?.sendData(buffer)
    }

    func close() {
        for channel in channels.values {
            channel.close()
        }
        channels.removeAll()
        openedChannelIDs.removeAll()
        connection.close()
        backend?.forgetPeer(id)
    }

    // MARK: Asynchronous surface

    func setLocalDescription(type: SDPType, sdp: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.setLocalDescription(
                RTCSessionDescription(type: Self.sdpType(type), sdp: sdp),
                completionHandler: errorCompletion(continuation)
            )
        }
    }

    func setRemoteDescription(type: SDPType, sdp: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.setRemoteDescription(
                RTCSessionDescription(type: Self.sdpType(type), sdp: sdp),
                completionHandler: errorCompletion(continuation)
            )
        }
    }

    func addIceCandidate(_ candidate: JSONValue) async throws {
        guard let sdp = candidate["candidate"]?.stringValue else { return }
        let rtc = RTCIceCandidate(
            sdp: sdp,
            sdpMLineIndex: Int32(candidate["sdpMLineIndex"]?.doubleValue ?? 0),
            sdpMid: candidate["sdpMid"]?.stringValue
        )
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.add(rtc, completionHandler: errorCompletion(continuation))
        }
    }

    func createOffer(simulcast: Bool) async throws -> JSONValue {
        // libwebrtc's native `offerForConstraints:` ignores lib-jitsi-meet's legacy
        // OfferToReceive{Audio,Video} constraints under Unified Plan, unlike browsers, which
        // turn them into recvonly m-lines. Without local tracks (a muted or viewer-only join)
        // that left an offer with no media sections and no BUNDLE group, which libwebrtc then
        // refused to apply: "max-bundle configured but session description has no BUNDLE
        // group". The P2P invite failed and surfaced as `conference.offerAnswerFailed`, killing
        // the meeting even though the JVB session was healthy. Seed the transceivers the
        // constraints stand for; lib-jitsi-meet mungs their direction from there.
        for mediaType in [RTCRtpMediaType.audio, RTCRtpMediaType.video]
        where !connection.transceivers.contains(where: { $0.mediaType == mediaType }) {
            let init_ = RTCRtpTransceiverInit()
            init_.direction = .recvOnly
            connection.addTransceiver(of: mediaType, init: init_)
        }
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveAudio": "TRUE",
                "OfferToReceiveVideo": "TRUE",
            ],
            optionalConstraints: nil
        )
        return try await withCheckedThrowingContinuation { continuation in
            connection.offer(for: constraints) { description, error in
                if let error {
                    continuation.resume(throwing: JitsiError.remote(error.localizedDescription))
                    return
                }
                continuation.resume(returning: Self.sessionJSON(description))
            }
        }
    }

    func createAnswer() async throws -> JSONValue {
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        return try await withCheckedThrowingContinuation { continuation in
            connection.answer(for: constraints) { description, error in
                if let error {
                    continuation.resume(throwing: JitsiError.remote(error.localizedDescription))
                    return
                }
                continuation.resume(returning: Self.sessionJSON(description))
            }
        }
    }

    /// Bitrate is a per-sender `RTCRtpEncodingParameters` property on iOS; reassigning
    /// `parameters` is what commits it to the transmission. `scalabilityMode` has no
    /// counterpart in this libwebrtc build (its encoding class stops at
    /// `maxBitrateBps`/`scaleResolutionDownBy`), so SVC stays a JS-side hint.
    func applyEncodingParameters(maxBitrateKbps: Int?, scalabilityMode _: String?) async throws {
        guard let kbps = maxBitrateKbps else { return }
        for sender in connection.senders {
            let parameters = sender.parameters
            for encoding in parameters.encodings {
                encoding.maxBitrateBps = NSNumber(value: kbps * 1000)
                encoding.minBitrateBps = NSNumber(value: max(1, kbps * 500))
            }
            sender.parameters = parameters
        }
    }

    func statistics() async throws -> JSONValue {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, Error>) in
            connection.statistics { report in
                // The JS shim wraps this array in an `RTCStatsReport` and lib-jitsi-meet walks
                // it browser-style: `type`, `timestamp` and the counters all live on the record.
                let entries = report.statistics.values.map { item -> JSONValue in
                    var record: [String: JSONValue] = [
                        "id": .string(item.id),
                        "type": .string(item.type),
                        "timestamp": .number(item.timestamp_us / 1000),
                    ]
                    for (key, value) in item.values {
                        record[key] = statValue(value)
                    }
                    return .object(record)
                }
                continuation.resume(returning: .array(Array(entries)))
            }
        }
    }

    // MARK: RTCPeerConnectionDelegate

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        onEvent(.signalingState(stateChanged.browserName))
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        onEvent(.iceConnectionState(newState.browserName))
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        onEvent(.iceGatheringState(newState.browserName))
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        onEvent(.connectionState(newState.browserName))
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        onEvent(.iceCandidate(endpoint: candidate.sdpMid, .object([
            "candidate": .string(candidate.sdp),
            "sdpMLineIndex": .number(Double(candidate.sdpMLineIndex)),
            "sdpMid": candidate.sdpMid.map(JSONValue.string) ?? .null,
        ])))
    }

    /// Unified Plan delivers every remote track through `didAdd receiver:streams:` below,
    /// which also carries the mid lib-jitsi-meet needs. Publishing here as well duplicated
    /// each video track, and the duplicate had no mid, so its remote m-line lookup failed.
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}

    /// Plan B only, and this backend always creates Unified Plan connections, so libwebrtc
    /// never calls it; remote track teardown arrives as `didRemove receiver:`.
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {
        // Nothing to forward: the JS facade only ever adds candidates.
    }

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        // lib-jitsi-meet drives negotiation; nothing to do here.
    }

    /// Unified Plan hands remote media to the app through receivers, and this is the only
    /// callback that fires for a JVB conference — `didAdd stream:` never does.
    func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didAdd rtpReceiver: RTCRtpReceiver,
        streams: [RTCMediaStream]
    ) {
        guard let track = rtpReceiver.track else { return }
        let streamID = streams.first?.streamId ?? ""
        let mid = mid(for: rtpReceiver)
        if let video = track as? RTCVideoTrack {
            publishRemote(video, streamID: streamID, mid: mid)
            return
        }
        onEvent(.incomingTrack(TrackSnapshot(
            id: track.trackId,
            mediaType: MediaType(rawValue: track.kind) ?? .audio,
            isLocal: false,
            muted: !track.isEnabled,
            videoType: .noVideo,
            deviceID: streamID.isEmpty ? nil : streamID,
            label: streamID
        ), streamID: streamID, mid: mid))
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        channels[dataChannel.label] = dataChannel
        dataChannel.delegate = self
        emitOpenIfNeeded(dataChannel)
    }

    // MARK: RTCDataChannelDelegate

    /// RTCDataChannel fires this for every ready-state transition (connecting → open →
    /// closing → closed). Only the open transition may reach the JS shim: during hangup the
    /// channel flips to closing/closed, and forwarding those as "open" re-runs
    /// lib-jitsi-meet's onopen after `leave()` already nulled `conference.room` — its
    /// listener dereferences `room.connectionTimes` and throws, which surfaces as
    /// "[shim] listener failed for pc:…event" in the log on every hangup.
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        emitOpenIfNeeded(dataChannel)
    }

    private func emitOpenIfNeeded(_ dataChannel: RTCDataChannel) {
        guard dataChannel.readyState == .open,
              openedChannelIDs.insert(dataChannel.channelId).inserted
        else { return }
        onEvent(.dataChannelOpen(label: dataChannel.label))
    }

    func dataChannel(
        _ dataChannel: RTCDataChannel,
        didReceiveMessageWith buffer: RTCDataBuffer
    ) {
        let text = String(data: buffer.data, encoding: .utf8)
        onEvent(.dataChannelMessage(label: dataChannel.label, text: text))
    }

    // MARK: Helpers

    private func publishRemote(_ track: RTCVideoTrack, streamID: String, mid: String?) {
        let snapshot = TrackSnapshot(
            id: track.trackId,
            mediaType: .video,
            isLocal: false,
            muted: !track.isEnabled,
            videoType: .camera,
            deviceID: streamID.isEmpty ? nil : streamID,
            label: streamID
        )
        backend?.registerRemote(track, snapshot: snapshot)
        onEvent(.incomingTrack(snapshot, streamID: streamID, mid: mid))
    }

    /// libwebrtc's delegate callback hands us a receiver, not its transceiver, but the
    /// receiver id is shared. lib-jitsi-meet needs the mid to find the remote SDP m-line.
    private func mid(for receiver: RTCRtpReceiver) -> String? {
        connection.transceivers
            .first { $0.receiver.receiverId == receiver.receiverId }?
            .mid
    }

    private static func sessionJSON(_ description: RTCSessionDescription?) -> JSONValue {
        .object([
            "type": .string(description?.type.browserName ?? "offer"),
            "sdp": .string(description?.sdp ?? ""),
        ])
    }

    private func errorCompletion(_ continuation: CheckedContinuation<Void, Error>) -> (Error?) -> Void {
        { error in
            if let error {
                continuation.resume(throwing: JitsiError.remote(error.localizedDescription))
            } else {
                continuation.resume()
            }
        }
    }

    private static func sdpType(_ type: SDPType) -> RTCSdpType {
        switch type {
        case .offer: return .offer
        case .answer: return .answer
        case .pranswer: return .prAnswer
        }
    }
}

/// Camera capture, fed into an `RTCVideoSource`.
///
/// Audio deliberately has no path here: on iOS libwebrtc owns microphone capture through
/// its own audio module once `RTCAudioSession` is active, which is exactly what
/// react-native-webrtc relies on, and the route/policy is `AudioSessionManager`'s job.
private final class CapturePipeline: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.jitsi.capture")
    private var videoOutput: AVCaptureVideoDataOutput?
    private var videoInput: AVCaptureDeviceInput?

    private let lock = NSLock()
    private var videoSource: RTCVideoSource?
    /// libwebrtc feeds a source through an `RTCVideoCapturer`, never the source directly.
    private var capturer: RTCVideoCapturer?
    private var started = false
    /// Last explicit format choice, re-applied after a camera switch or a capture restart.
    private var requestedConstraints: VideoConstraints?

    /// iOS 17+ rotates the buffers themselves, so the frame carries no rotation metadata and
    /// every consumer (self view and remote peers) gets an upright picture. Older systems fall
    /// back to tagging the landscape buffer with a rotation derived from the device orientation.
    private var rotationCoordinator: AnyObject?
    private var captureAngleObservation: NSKeyValueObservation?
    private var orientationObserver: NSObjectProtocol?
    private var physicalRotation = false
    private var deviceOrientation: UIDeviceOrientation = .portrait

    /// Passing nil releases the sink; the session stops when nothing is left to feed.
    func setVideoSource(_ source: RTCVideoSource?, deviceID: String?) {
        lock.lock()
        videoSource = source
        capturer = source.map { RTCVideoCapturer(delegate: $0) }
        lock.unlock()
        guard let device = cameraDevice(for: deviceID), session.isRunning else { return }
        reattachVideoInput(to: device)
    }

    func startIfNeeded() async {
        lock.lock()
        let shouldStart = !started
        started = shouldStart
        lock.unlock()
        guard shouldStart else { return }

        session.sessionPreset = .high
        if let device = cameraDevice(for: nil),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input)
        {
            session.addInput(input)
            videoInput = input
        }

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) {
            session.addOutput(output)
            videoOutput = output
        }
        if let device = videoInput?.device {
            configureRotation(for: device)
            lock.lock()
            let constraints = requestedConstraints
            lock.unlock()
            if let constraints {
                try? apply(constraints, to: device)
            }
        }

        // `startRunning` blocks; keep it off the caller's task.
        queue.async {
            self.session.startRunning()
        }
    }

    func stop() async {
        lock.lock()
        let wasStarted = started
        started = false
        lock.unlock()
        guard wasStarted else { return }

        stopRotationTracking()
        session.stopRunning()
        if let input = videoInput {
            session.removeInput(input)
            videoInput = nil
        }
        if let output = videoOutput {
            session.removeOutput(output)
            videoOutput = nil
        }
    }

    func stopIfIdle() async {
        lock.lock()
        let idle = videoSource == nil
        lock.unlock()
        if idle {
            await stop()
        }
    }

    func videoCapabilities() async throws -> VideoTrackCapabilities {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard let device = self.videoInput?.device ?? self.cameraDevice(for: nil) else {
                    continuation.resume(throwing: JitsiError.unsupported("no camera to inspect"))
                    return
                }
                continuation.resume(returning: Self.capabilities(of: device))
            }
        }
    }

    func applyVideoConstraints(_ constraints: VideoConstraints) async throws -> VideoTrackCapabilities {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    guard let device = self.videoInput?.device ?? self.cameraDevice(for: nil) else {
                        throw JitsiError.unsupported("no camera to configure")
                    }
                    try self.apply(constraints, to: device)
                    continuation.resume(returning: Self.capabilities(of: device))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Changes the running session's format. The session preset has to be `inputPriority`
    /// for `activeFormat` to take effect, and the frame-rate durations must stay inside the
    /// chosen format's supported ranges.
    private func apply(_ constraints: VideoConstraints, to device: AVCaptureDevice) throws {
        guard constraints.width.map({ $0 > 0 }) ?? true,
              constraints.height.map({ $0 > 0 }) ?? true,
              constraints.frameRate.map({ $0 > 0 }) ?? true
        else {
            throw JitsiError.invalidArgument("width, height and frameRate must be positive")
        }
        if session.sessionPreset != .inputPriority {
            session.beginConfiguration()
            session.sessionPreset = .inputPriority
            session.commitConfiguration()
        }
        guard let format = Self.bestFormat(
            for: device,
            width: constraints.width,
            height: constraints.height,
            frameRate: constraints.frameRate)
        else {
            throw JitsiError.unsupported("the camera exposes no usable format")
        }
        let frameRate = Self.frameRate(for: format, requested: constraints.frameRate)
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.activeFormat = format
        let duration = CMTime(value: 1, timescale: CMTimeScale(frameRate.rounded()))
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
        lock.lock()
        requestedConstraints = constraints
        lock.unlock()
    }

    private static func dimensions(of format: AVCaptureDevice.Format) -> (width: Int, height: Int) {
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        return (Int(dimensions.width), Int(dimensions.height))
    }

    private static func bestFormat(
        for device: AVCaptureDevice,
        width: Int?,
        height: Int?,
        frameRate: Int?
    ) -> AVCaptureDevice.Format? {
        let current = dimensions(of: device.activeFormat)
        let targetWidth = width ?? (current.width > 0 ? current.width : 1280)
        let targetHeight = height ?? (current.height > 0 ? current.height : 720)
        let targetAspect = log(Double(targetWidth) / Double(targetHeight))

        let candidates = device.formats.filter {
            let size = dimensions(of: $0)
            return size.width > 0 && size.height > 0
        }
        // Prefer a format that can actually run the requested frame rate; fall back to the
        // resolution-only choice when no format offers it.
        let rateMatches = frameRate.map { requested in
            candidates.filter { format in
                format.videoSupportedFrameRateRanges.contains {
                    Double(requested) >= $0.minFrameRate && Double(requested) <= $0.maxFrameRate
                }
            }
        } ?? []
        let pool = rateMatches.isEmpty ? candidates : rateMatches
        return pool.min {
            score($0, width: targetWidth, height: targetHeight) < score($1, width: targetWidth, height: targetHeight)
        }
    }

    /// Matches aspect ratio first and resolution second, both in log space, so a 16:9 request
    /// does not land on a 4:3 format that merely has more pixels.
    private static func score(
        _ format: AVCaptureDevice.Format,
        width: Int,
        height: Int
    ) -> Double {
        let size = dimensions(of: format)
        let aspectPenalty = abs(log(Double(size.width) / Double(size.height)) - log(Double(width) / Double(height)))
        let sizePenalty = abs(log(Double(size.width) / Double(width))) + abs(log(Double(size.height) / Double(height)))
        return aspectPenalty * 4 + sizePenalty
    }

    private static func frameRate(for format: AVCaptureDevice.Format, requested: Int?) -> Double {
        let ranges = format.videoSupportedFrameRateRanges
        guard let minimum = ranges.map(\.minFrameRate).min(),
              let maximum = ranges.map(\.maxFrameRate).max()
        else { return 30 }
        let desired = Double(requested ?? Int(min(30, maximum)))
        if ranges.contains(where: { desired >= $0.minFrameRate && desired <= $0.maxFrameRate }) {
            return desired
        }
        return min(max(desired, minimum), maximum)
    }

    private static func capabilities(of device: AVCaptureDevice) -> VideoTrackCapabilities {
        var formatsBySize: [String: VideoTrackCapabilities.Format] = [:]
        for format in device.formats {
            let size = dimensions(of: format)
            guard size.width > 0, size.height > 0 else { continue }
            let ranges = format.videoSupportedFrameRateRanges
            let minimum = ranges.map(\.minFrameRate).min() ?? 0
            let maximum = ranges.map(\.maxFrameRate).max() ?? 0
            let key = "\(size.width)x\(size.height)"
            if let existing = formatsBySize[key] {
                formatsBySize[key] = VideoTrackCapabilities.Format(
                    width: size.width,
                    height: size.height,
                    minFrameRate: min(existing.minFrameRate, minimum),
                    maxFrameRate: max(existing.maxFrameRate, maximum))
            } else {
                formatsBySize[key] = VideoTrackCapabilities.Format(
                    width: size.width,
                    height: size.height,
                    minFrameRate: minimum,
                    maxFrameRate: maximum)
            }
        }
        let active = dimensions(of: device.activeFormat)
        let duration = device.activeVideoMinFrameDuration
        let activeFrameRate = duration.isValid && duration.seconds > 0 ? 1 / duration.seconds : nil
        return VideoTrackCapabilities(
            formats: formatsBySize.values.sorted {
                $0.width * $0.height > $1.width * $1.height
            },
            activeWidth: active.width > 0 ? active.width : nil,
            activeHeight: active.height > 0 ? active.height : nil,
            activeFrameRate: activeFrameRate,
            deviceID: device.uniqueID)
    }

    /// Switches the input device while the session keeps running. Serialized on the capture
    /// queue because `beginConfiguration`/`commitConfiguration` must not interleave with a
    /// sample callback or with `setVideoSource`.
    func switchCamera() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let target = Self.oppositeCamera(to: self.videoInput?.device)
                guard let target else {
                    continuation.resume(throwing: JitsiError.unsupported("no camera on the other side"))
                    return
                }
                self.reattachVideoInput(to: target)
                continuation.resume(returning: target.uniqueID)
            }
        }
    }

    private static func oppositeCamera(to device: AVCaptureDevice?) -> AVCaptureDevice? {
        let target: AVCaptureDevice.Position = device?.position == .front ? .back : .front
        if let wide = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: target) {
            return wide
        }
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInDualWideCamera, .builtInTripleCamera],
            mediaType: .video,
            position: target
        )
        return discovery.devices.first
    }

    /// Front camera first: a phone conference usually starts with a self view, and the
    /// JS layer switches devices by calling `setVideoSource` with a new unique id.
    private func cameraDevice(for id: String?) -> AVCaptureDevice? {
        if let id, let device = AVCaptureDevice(uniqueID: id) {
            return device
        }
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            ?? AVCaptureDevice.default(for: .video)
    }

    private func reattachVideoInput(to device: AVCaptureDevice) {
        session.beginConfiguration()
        if let input = videoInput {
            session.removeInput(input)
        }
        if let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
            session.addInput(input)
            videoInput = input
        }
        session.commitConfiguration()
        configureRotation(for: device)
        // A new camera starts on its default format; keep the resolution the host picked.
        lock.lock()
        let constraints = requestedConstraints
        lock.unlock()
        if let constraints {
            try? apply(constraints, to: device)
        }
    }

    /// Binds the capture connection to the device's upright angle. `videoOrientation` is a
    /// static default (`.landscapeLeft` on the front camera) and says nothing about how the
    /// phone is actually held, which is why the old mapping rotated every frame 90° off.
    private func configureRotation(for device: AVCaptureDevice) {
        stopRotationTracking()
        guard let connection = videoOutput?.connection(with: .video) else { return }

        if #available(iOS 17.0, *) {
            let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
            rotationCoordinator = coordinator
            captureAngleObservation = coordinator.observe(
                \.videoRotationAngleForHorizonLevelCapture,
                options: [.initial, .new]
            ) { [weak self] _, change in
                guard let self, let angle = change.newValue else { return }
                self.queue.async { self.applyCaptureAngle(angle, to: connection) }
            }
            return
        }

        // iOS 15/16: no coordinator, so derive the metadata rotation from the device itself.
        // Orientation notifications are a UIKit facility and belong on the main thread.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.orientationObserver == nil else { return }
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            let initial = Self.uprightOrientation(UIDevice.current.orientation)
            self.lock.lock()
            self.deviceOrientation = initial
            self.lock.unlock()
            self.orientationObserver = NotificationCenter.default.addObserver(
                forName: UIDevice.orientationDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                let orientation = UIDevice.current.orientation
                guard orientation.isPortrait || orientation.isLandscape else { return }
                self.lock.lock()
                self.deviceOrientation = orientation
                self.lock.unlock()
            }
        }
    }

    @available(iOS 17.0, *)
    private func applyCaptureAngle(_ angle: CGFloat, to connection: AVCaptureConnection) {
        guard connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
        lock.lock()
        physicalRotation = true
        lock.unlock()
        NSLog("[jitsi-media] capture rotated to %.0f° (buffers now upright)", angle)
    }

    private func stopRotationTracking() {
        captureAngleObservation?.invalidate()
        captureAngleObservation = nil
        rotationCoordinator = nil
        if let observer = orientationObserver {
            NotificationCenter.default.removeObserver(observer)
            orientationObserver = nil
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
        }
        lock.lock()
        physicalRotation = false
        lock.unlock()
    }

    private static func uprightOrientation(_ orientation: UIDeviceOrientation) -> UIDeviceOrientation {
        orientation.isPortrait || orientation.isLandscape ? orientation : .portrait
    }

    /// Must be spelled `captureOutput(_:didOutput:from:)`: Swift does not check optional
    /// delegate methods, so a different base name silently never gets called.
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sample: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard output == videoOutput, let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
        lock.lock()
        let source = videoSource
        let capturer = self.capturer
        let rotated = physicalRotation
        let orientation = deviceOrientation
        lock.unlock()
        guard let source, let capturer else { return }

        let frame = RTCVideoFrame(
            buffer: RTCCVPixelBuffer(pixelBuffer: buffer),
            rotation: rotated ? ._0 : Self.frameRotation(for: orientation),
            timeStampNs: Int64(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)) * 1e9)
        )
        // `RTCVideoSource` is the capturer's delegate, so this is the capture entry point.
        source.capturer(capturer, didCapture: frame)
    }

    /// Degrees the encoded frame has to be rotated clockwise to be upright, which is what
    /// libwebrtc's rotation field means, not the interface orientation itself. Only used on
    /// iOS 15/16; portrait is the calibrated default for a landscape-mounted sensor.
    private static func frameRotation(for orientation: UIDeviceOrientation) -> RTCVideoRotation {
        switch orientation {
        case .portrait: return ._90
        case .portraitUpsideDown: return ._270
        case .landscapeLeft: return ._180
        case .landscapeRight: return ._0
        default: return ._90
        }
    }
}

/// WebRTC's stats values are NSNumbers, NSStrings and containers of both; the JS layer only
/// ever reads numbers and strings off a record, so anything else travels as its description.
private func statValue(_ value: NSObject) -> JSONValue {
    if let text = value as? String { return .string(text) }
    if let number = value as? NSNumber { return .number(number.doubleValue) }
    return .string("\(value)")
}

// MARK: - W3C state names
//
// libwebrtc reports `NS_ENUM` values while the JS `RTCPeerConnection` facade, and therefore
// lib-jitsi-meet, compares against the strings the browser API uses.

private extension RTCSignalingState {
    var browserName: String {
        switch self {
        case .stable: return "stable"
        case .haveLocalOffer: return "have-local-offer"
        case .haveLocalPrAnswer: return "have-local-pranswer"
        case .haveRemoteOffer: return "have-remote-offer"
        case .haveRemotePrAnswer: return "have-remote-pranswer"
        case .closed: return "closed"
        }
    }
}

private extension RTCIceConnectionState {
    var browserName: String {
        switch self {
        case .new, .count: return "new"
        case .checking: return "checking"
        case .connected: return "connected"
        case .completed: return "completed"
        case .failed: return "failed"
        case .disconnected: return "disconnected"
        case .closed: return "closed"
        }
    }
}

private extension RTCIceGatheringState {
    var browserName: String {
        switch self {
        case .new: return "new"
        case .gathering: return "gathering"
        case .complete: return "complete"
        }
    }
}

private extension RTCPeerConnectionState {
    var browserName: String {
        switch self {
        case .new: return "new"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .disconnected: return "disconnected"
        case .failed: return "failed"
        case .closed: return "closed"
        }
    }
}

private extension RTCSdpType {
    var browserName: String {
        switch self {
        case .offer: return "offer"
        case .prAnswer: return "pranswer"
        case .answer: return "answer"
        case .rollback: return "rollback"
        }
    }
}
#endif
