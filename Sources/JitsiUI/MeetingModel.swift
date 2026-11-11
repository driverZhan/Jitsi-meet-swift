import AVFoundation
import JitsiCore
import JitsiMedia
import SwiftUI

/// SwiftUI-facing store for one meeting.
///
/// It owns no protocol logic: state comes from `JitsiConference` snapshots plus the shared
/// event hub, and every control funnels into the engine. The grid therefore renders from
/// plain values and never reaches into the JS runtime.
@MainActor
public final class MeetingModel: ObservableObject {
    public struct Tile: Identifiable, Equatable {
        public let id: ParticipantID
        public let displayName: String
        public let videoTrackID: TrackID?
        public let isLocal: Bool
        public let isDominantSpeaker: Bool
        public let raisedHand: Bool
        public let audioMuted: Bool
        public let connectionQuality: String?
        public let role: ParticipantRole
        public let isModerator: Bool
        public let avatarURL: String?
        public let email: String?
    }

    public struct Line: Identifiable, Equatable {
        public let id = UUID()
        public let author: String
        public let text: String
        public let isPrivate: Bool
    }

    public struct Poll: Identifiable, Equatable {
        public let id: String
        public let question: String
        public let answers: [String]
        /// Polls replayed from the server's history arrive before anyone votes.
        public let isHistory: Bool
        /// Votes received since joining, per answer index. The polls component does not
        /// attach a voter identity, so these are tallies rather than per-participant state.
        public var counts: [Int]
        public var hasAnswered: Bool

        public var totalVotes: Int { counts.reduce(0, +) }
    }

    public struct Caption: Identifiable, Equatable {
        public let id: String
        public let speaker: String
        public let text: String
        public let isInterim: Bool
    }

    @Published public private(set) var connectionStatus: ConnectionStatus = .idle
    @Published public private(set) var isJoined = false
    @Published public private(set) var tiles: [Tile] = []
    @Published public private(set) var isAudioMuted = false
    @Published public private(set) var isVideoMuted = false
    @Published public private(set) var isRecording = false
    @Published public private(set) var isScreenSharing = false
    @Published public private(set) var isHandRaised = false
    /// True while the room has a password; updated by `LOCK_STATE_CHANGED`.
    @Published public private(set) var isLocked = false
    @Published public private(set) var quality: String?
    @Published public private(set) var message: String?
    @Published public private(set) var transcript: [Line] = []
    @Published public private(set) var polls: [Poll] = []
    /// False when the deployment has no Prosody polls component.
    @Published public private(set) var pollsSupported = false
    @Published public private(set) var captions: [Caption] = []
    @Published public private(set) var transcriptionActive = false
    /// Reachability from the engine's path monitor. A reconnect attempt is held while this
    /// is false instead of failing three times against a radio that is still coming back.
    @Published public private(set) var isNetworkOnline = true
    /// CPU, memory, thermal state and first-remote-frame latency; sampling starts on join.
    public let metrics = MeetingMetrics()

    public var isModerator: Bool { conference?.isModerator ?? false }

    /// False when the deployment has no end-conference component, so the control should hide.
    public var canEndConference: Bool { conference?.canEndConference ?? false }

    /// Policy the room publishes for new joiners; nil until the state snapshot arrives.
    public var startMutedPolicy: StartMutedPolicy? { conference?.startMutedPolicy }

    /// True when `retryConnection()` can start a fresh rejoin: a session exists, the room
    /// is not up, and no automatic attempt is already running.
    public var canRetryConnection: Bool {
        session != nil && !isJoined && rejoinTask == nil
    }

    /// Host hook for JWT deployments. lib-jitsi-meet asks for a replacement while a dropped
    /// stream is being resumed and cancels the resume if none arrives within 3 seconds.
    public var tokenProvider: (() async -> String?)?

    public private(set) var conference: JitsiConference?

    private let discovery = CaptureCoordinator()
    private var hubSubscription: Subscription?
    private var appliedReceivePolicy: (maxHeight: Int, lastN: Int)?
    /// Everything `start` was called with, so a dropped connection can be rebuilt without
    /// asking the app again.
    private struct Session {
        let connection: ConnectionOptions
        let conference: ConferenceOptions
        let capture: [MediaType]
    }
    private var session: Session?
    private var rejoinTask: Task<Void, Never>?
    private var rejoinAttempt = 0
    /// Set once the room has been joined. A lifecycle retry must not restart the initial
    /// join or a lobby wait, where `isJoined` is also false.
    private var hasJoined = false
    /// Set when the scene leaves the foreground. Only a real background round-trip grants a
    /// fresh rejoin quota, so a transient inactive state does not restart anything.
    private var wasBackgrounded = false
    /// Drops that were each followed by a successful rejoin. Upstream resets its retry
    /// counter on success, which is right for a single drop and wrong for a flapping radio:
    /// every recovery hid the next drop behind a 1.5 s retry, so a network that dies every
    /// 30 seconds kept the user in a permanent reconnect loop. This decays only after the
    /// connection stayed up for `stableWindow`.
    private var instability = 0
    private var stabilityTask: Task<Void, Never>?
    /// Last `setQuality` choice, re-applied to the rebuilt senders after a rejoin.
    private var videoQualityHeight: Int?
    /// Upstream's `MAX_CONNECTION_RETRIES`: after three failed rejoins in a row the room is
    /// gone. Successes do not consume this, so a flapping network is not dropped for good.
    private static let maxRejoinAttempts = 3
    private static let stableWindow: TimeInterval = 30
    private static let maxInstability = 4

    public init() {}

    deinit {
        hubSubscription?.unsubscribe()
    }

    // MARK: - Session

    /// Connect, join and open capture in one call, because a phone UI always wants that
    /// order and every step failure should surface on the same `message` binding.
    public func start(
        _ connection: ConnectionOptions,
        conference options: ConferenceOptions,
        capture: [MediaType] = [.audio, .video]
    ) async {
        do {
            guard let engine = JitsiMeet.shared.engine else { throw JitsiError.engineNotInstalled }
            observe()

            session = Session(connection: connection, conference: options, capture: capture)
            rejoinAttempt = 0
            instability = 0
            hasJoined = false
            wasBackgrounded = false
            stabilityTask?.cancel()
            stabilityTask = nil
            // The monitor reports once on start, possibly before anything subscribed.
            isNetworkOnline = engine.isNetworkOnline
            let room = makeRoom(options)

            try await engine.connect(connection)
            // Tracks must exist before the room join: the JVB session-initiate arrives while
            // joining and its answer carries the m-lines for every track already registered.
            // Adding them afterwards leaves the senders empty on the bridge side.
            try await engine.prepareConference(options)
            if !capture.isEmpty {
                _ = try await room.capture(capture)
                syncMutedState(from: room)
            }
            try await engine.joinConference(options)
            rebuildTiles()
        } catch {
            message = error.localizedDescription
        }
    }

    public func leave() async {
        rejoinTask?.cancel()
        rejoinTask = nil
        rejoinAttempt = 0
        instability = 0
        hasJoined = false
        wasBackgrounded = false
        stabilityTask?.cancel()
        stabilityTask = nil
        session = nil
        await conference?.leave()
        await JitsiMeet.shared.engine?.disconnect()
        hubSubscription?.unsubscribe()
        hubSubscription = nil
        conference = nil
        isJoined = false
        isHandRaised = false
        isLocked = false
        isScreenSharing = false
        isRecording = false
        videoQualityHeight = nil
        tiles = []
        polls = []
        pollsSupported = false
        captions = []
        transcriptionActive = false
    }

    /// Host lifecycle hook. Pass `scenePhase == .active`. Returning from the background
    /// with the room already gone grants a fresh rejoin quota; a healthy call and a session
    /// that never joined (initial join or lobby wait) are left untouched.
    public func setAppActive(_ active: Bool) {
        guard session != nil else {
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
        // A suspended rejoin resumes with the app; only a finished loop needs a new quota.
        guard rejoinTask == nil else { return }
        retryConnection()
    }

    /// Manual recovery for the failures the automatic path deliberately does not retry:
    /// server 5xx, BOSH 499/400 and a Prosody-initiated disconnect. Reuses the rejoin loop,
    /// so the jittered backoff and the fresh-token path still apply.
    public func retryConnection() {
        guard session != nil, !isJoined, rejoinTask == nil else { return }
        rejoinAttempt = 0
        message = "Reconnecting…"
        scheduleRejoin()
    }

    private func scheduleRejoin() {
        guard session != nil, rejoinTask == nil else { return }
        rejoinTask = Task { [weak self] in
            guard let self else { return }
            await self.performRejoin()
            self.rejoinTask = nil
        }
    }

    private func makeRoom(_ options: ConferenceOptions) -> JitsiConference {
        let room = JitsiConference(options: options)
        conference = room
        // The new peer connection starts with the lib defaults, so the policy has to be
        // pushed again even when the grid size did not change.
        appliedReceivePolicy = nil
        room.onStateChange = { [weak self] in
            Task { @MainActor in
                self?.isLocked = room.isLocked
                self?.rebuildTiles()
            }
        }
        return room
    }

    /// Full rejoin, the same recovery a jitsi-meet browser performs on
    /// `CONNECTION_DROPPED`. The lib has already disposed the local tracks, so capture runs
    /// again and the user's mute choices are re-applied to the new tracks.
    private func performRejoin() async {
        guard let session = session, let engine = JitsiMeet.shared.engine else { return }
        while rejoinAttempt < Self.maxRejoinAttempts {
            // An offline radio fails every attempt the same way, so hold the quota until a
            // path exists and then retry at once. Upstream jitsi-meet gates its reconnect on
            // the same network event instead of hammering a dead interface.
            var waitedForNetwork = false
            if !isNetworkOnline {
                message = "Waiting for network…"
                await waitForNetwork()
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
                guard !Task.isCancelled else { return }
            }
            message = instability >= 3
                ? "Network unstable, reconnecting… (\(rejoinAttempt)/\(Self.maxRejoinAttempts))"
                : "Reconnecting… (\(rejoinAttempt)/\(Self.maxRejoinAttempts))"

            let room = makeRoom(session.conference)
            let connection = await connectionWithFreshToken(session.connection)
            await engine.resetForRejoin()
            do {
                try await engine.connect(connection)
                try await engine.prepareConference(session.conference)
                if !session.capture.isEmpty {
                    _ = try await room.capture(session.capture)
                    if isAudioMuted { try? await room.setMuted(true, mediaType: .audio) }
                    if isVideoMuted { try? await room.setMuted(true, mediaType: .video) }
                }
                // `join()` returns while the MUC join is still in flight; only the joined
                // event says the room is actually up, and a failure after the fact would
                // otherwise be reported as a successful reconnect.
                try await engine.joinConference(session.conference, waitForJoin: 15)
                // The wait can last up to the join timeout; a leave() in that window must
                // win over restoring state into a room the user already left.
                guard !Task.isCancelled else { return }
                rejoinAttempt = 0
                message = nil
                scheduleStabilityReset()
                await restoreSessionState(room)
                rebuildTiles()
                return
            } catch {
                message = "Reconnect attempt \(rejoinAttempt) failed: \(error.localizedDescription)"
            }
        }
        // Out of attempts: give the audio session back instead of holding the microphone
        // open in front of a dead connection.
        await engine.disconnect()
        message = "Connection lost. Leave and rejoin to continue."
    }

    /// Clears the escalated backoff only once the link has stayed up for a while. Cancelled
    /// by the next drop, so a flapping Wi-Fi keeps its accumulated delay.
    private func scheduleStabilityReset() {
        stabilityTask?.cancel()
        stabilityTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.stableWindow * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.instability = 0
            self.stabilityTask = nil
        }
    }

    /// Polls the path monitor between attempts. Four hundred milliseconds is below what a
    /// user can perceive as a delayed reconnect and keeps this cancellation-safe: a
    /// continuation resumed by an event would leak when `leave()` cancels the task. Capped
    /// at 30s because `.satisfied` follows the internet route, which a restricted LAN can
    /// fail while the signalling host is still reachable.
    private func waitForNetwork() async {
        let deadline = Date().addingTimeInterval(30)
        while !isNetworkOnline && !Task.isCancelled && Date() < deadline {
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
    }

    /// A JWT is usually shorter-lived than a call. Reusing the token from the original join
    /// makes every attempt after it expired fail authentication, and the lib only asks for a
    /// replacement while resuming a live stream, never for a fresh connect.
    private func connectionWithFreshToken(_ connection: ConnectionOptions) async -> ConnectionOptions {
        guard connection.token != nil, let provider = tokenProvider,
              let token = await provider(), !token.isEmpty
        else { return connection }
        var refreshed = connection
        refreshed.token = token
        return refreshed
    }

    /// Room-level state the rebuild does not carry over: presence the user set, the sender
    /// constraint they picked, and a desktop track whose capture the lib disposed.
    private func restoreSessionState(_ room: JitsiConference) async {
        if isHandRaised { try? await room.raiseHand(true) }
        if let height = videoQualityHeight {
            try? await JitsiMeet.shared.engine?.setVideoQuality(height)
        }
        if isScreenSharing {
            do {
                _ = try await room.startScreenShare()
            } catch {
                isScreenSharing = false
                message = "Screen share stopped: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Controls

    public func toggleAudio() {
        guard let room = conference else { return }
        let next = !isAudioMuted
        Task {
            do {
                try await room.setMuted(next, mediaType: .audio)
                isAudioMuted = next
            } catch {
                message = error.localizedDescription
            }
        }
    }

    public func toggleVideo() {
        guard let room = conference else { return }
        let next = !isVideoMuted
        Task {
            do {
                try await room.setMuted(next, mediaType: .video)
                isVideoMuted = next
            } catch {
                message = error.localizedDescription
            }
        }
    }

    public func switchCamera() {
        guard let room = conference else { return }
        Task {
            do {
                try await room.switchCamera()
            } catch {
                message = error.localizedDescription
            }
        }
    }

    /// Resolution/frame-rate change that keeps the existing track and sender, so the call is
    /// not renegotiated.
    public func applyVideoConstraints(width: Int? = nil, height: Int? = nil, frameRate: Int? = nil) {
        guard let room = conference else { return }
        Task {
            do {
                _ = try await room.applyVideoConstraints(
                    VideoConstraints(width: width, height: height, frameRate: frameRate))
            } catch {
                message = error.localizedDescription
            }
        }
    }

    /// Camera formats for a resolution picker; nil when no local camera is live.
    public func videoCapabilities() async -> VideoTrackCapabilities? {
        guard let room = conference else { return nil }
        return try? await room.videoCapabilities()
    }

    /// Creates the desktop track before the user starts the system broadcast; frames begin
    /// flowing as soon as the broadcast extension connects to the App Group socket.
    public func startScreenShare() {
        guard let room = conference else { return }
        Task {
            do {
                _ = try await room.startScreenShare()
                isScreenSharing = true
            } catch {
                message = error.localizedDescription
            }
        }
    }

    public func stopScreenShare() {
        guard let room = conference else { return }
        Task {
            await room.stopScreenShare()
            isScreenSharing = false
        }
    }

    public func setQuality(_ height: Int) {
        videoQualityHeight = height
        Task {
            do {
                try await JitsiMeet.shared.engine?.setVideoQuality(height)
            } catch {
                message = error.localizedDescription
            }
        }
    }

    /// Writes the `jitsi_participant_raiseHand` presence extension every client reads. The
    /// local user has no participant row of their own, so the state is kept here.
    public func toggleHand() {
        guard let room = conference else { return }
        let next = !isHandRaised
        Task {
            do {
                try await room.raiseHand(next)
                isHandRaised = next
                rebuildTiles()
            } catch {
                message = error.localizedDescription
            }
        }
    }

    public func sendChat(_ text: String) {
        guard let room = conference, !text.isEmpty else { return }
        transcript.append(Line(author: "me", text: text, isPrivate: false))
        Task {
            do {
                try await room.sendChatMessage(text)
            } catch {
                message = error.localizedDescription
            }
        }
    }

    /// Structured payload for jitsi-meet style messages; not added to the local chat transcript
    /// because the UI has no renderer for it.
    public func sendJSONMessage(_ payload: JSONValue, to participantID: ParticipantID? = nil) {
        guard let room = conference else { return }
        Task {
            do {
                try await room.sendJSONMessage(payload, to: participantID)
            } catch {
                message = error.localizedDescription
            }
        }
    }

    /// Asks the server to mute another participant. Only moderators are allowed; the
    /// server rejects everyone else.
    public func muteParticipant(_ participantID: ParticipantID, mediaType: MediaType) {
        guard let room = conference, participantID != "local" else { return }
        Task {
            do {
                try await room.mute(participantID, mediaType: mediaType)
            } catch {
                message = error.localizedDescription
            }
        }
    }

    public func kick(_ participantID: ParticipantID) {
        guard let room = conference, participantID != "local" else { return }
        Task {
            do {
                try await room.kick(participantID)
            } catch {
                message = error.localizedDescription
            }
        }
    }

    // MARK: - Conference control (moderator)

    /// Ends the room for everyone. `canEndConference` tells the UI whether to offer it.
    public func endConference() {
        guard let room = conference else { return }
        Task {
            do {
                try await room.end()
            } catch {
                message = error.localizedDescription
            }
        }
    }

    public func lockRoom(password: String = "") {
        guard let room = conference else { return }
        Task {
            do {
                try await room.lock(password: password)
            } catch {
                message = error.localizedDescription
            }
        }
    }

    public func unlockRoom() {
        guard let room = conference else { return }
        Task {
            do {
                try await room.unlock()
            } catch {
                message = error.localizedDescription
            }
        }
    }

    public func grantModerator(_ participantID: ParticipantID) {
        guard let room = conference, participantID != "local" else { return }
        Task {
            do {
                try await room.grantOwner(participantID)
            } catch {
                message = error.localizedDescription
            }
        }
    }

    public func revokeModerator(_ participantID: ParticipantID) {
        guard let room = conference else { return }
        Task {
            do {
                try await room.revokeOwner(participantID)
            } catch {
                message = error.localizedDescription
            }
        }
    }

    /// Marks the local user as having joined without audio; peers skip the join chime.
    public func setSilent(_ silent: Bool) {
        guard let room = conference else { return }
        Task {
            do {
                try await room.setSilent(silent)
            } catch {
                message = error.localizedDescription
            }
        }
    }

    public func setSubject(_ subject: String) {
        guard let room = conference else { return }
        Task {
            do {
                try await room.setSubject(subject)
            } catch {
                message = error.localizedDescription
            }
        }
    }

    public func setStartMutedPolicy(audio: Bool, video: Bool) {
        guard let room = conference else { return }
        Task {
            do {
                try await room.setStartMutedPolicy(audio: audio, video: video)
            } catch {
                message = error.localizedDescription
            }
        }
    }

    public func createPoll(question: String, answers: [String]) {
        guard let room = conference else { return }
        Task {
            do {
                try await room.createPoll(question: question, answers: answers)
            } catch {
                message = error.localizedDescription
            }
        }
    }

    public func answerPoll(_ pollID: String, selections: [Bool]) {
        guard let room = conference else { return }
        if let index = polls.firstIndex(where: { $0.id == pollID }) {
            polls[index].hasAnswered = true
        }
        Task {
            do {
                try await room.answerPoll(pollID, answers: selections)
            } catch {
                message = error.localizedDescription
            }
        }
    }

    /// Cameras and microphones, for a device picker.
    public func devices() -> [DeviceDescriptor] {
        discovery.enumerate()
    }

    /// Frames for one track. Each surface gets its own stream, and the backend fan-out
    /// keeps only the newest frame per track.
    public func frames(for trackID: TrackID) -> AsyncStream<VideoPixelFrame> {
        guard let engine = JitsiMeet.shared.engine else {
            return AsyncStream<VideoPixelFrame> { $0.finish() }
        }
        let upstream = engine.frameStream(for: trackID)
        guard conference?.remoteTracks[trackID] != nil else {
            return upstream
        }
        // Remote tiles are the ones worth timing: the first decoded frame is what the user
        // perceives as "the call started". The wrapper only measures the first one.
        return AsyncStream { continuation in
            let task = Task { [metrics] in
                var recorded = false
                for await frame in upstream {
                    if !recorded {
                        recorded = true
                        metrics.markRemoteVideoFrame()
                    }
                    continuation.yield(frame)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Reduction

    private func observe() {
        hubSubscription?.unsubscribe()
        hubSubscription = JitsiMeet.shared.events.subscribe { [weak self] event in
            Task { @MainActor in self?.apply(event) }
        }
    }

    private func apply(_ event: MeetingEvent) {
        switch event {
        case .connectionStatus(let status, let detail):
            connectionStatus = status
            if let detail { message = detail }
        case .conferenceJoined:
            isJoined = true
            hasJoined = true
            metrics.markJoined()
            metrics.start()
            loadPollsSupport()
        case .conferenceLeft(let reason):
            isJoined = false
            metrics.stop()
            message = reason
        case .conferenceFailed(let error):
            isJoined = false
            metrics.stop()
            message = error.localizedDescription
        case .connectionInterrupted:
            message = "Media connection interrupted — reconnecting…"
        case .connectionRestored:
            if message == "Media connection interrupted — reconnecting…" {
                message = nil
            }
        case .networkChanged(let online):
            isNetworkOnline = online
        case .lockStateChanged(let locked):
            isLocked = locked
        case .connectionLost:
            isJoined = false
            metrics.stop()
            // A rejoin that only survived a few seconds does not make the network healthy,
            // so the backoff keeps escalating until the link proves itself stable.
            stabilityTask?.cancel()
            stabilityTask = nil
            instability = min(instability + 1, Self.maxInstability)
            scheduleRejoin()
        case .tokenExpired:
            // Without a host-supplied token the pending resume is cancelled by the lib and
            // the connection drops, which then triggers the rejoin above.
            if let provider = tokenProvider {
                Task {
                    guard let token = await provider(), !token.isEmpty else { return }
                    try? await JitsiMeet.shared.engine?.refreshToken(token)
                }
            } else {
                message = "Session token expired"
            }
        case .chatMessage(let from, let text, let isPrivate):
            transcript.append(Line(author: from, text: text, isPrivate: isPrivate))
        case .endpointMessage(let from, let content):
            applyCaption(from: from, content: content)
        case .recordingStateChanged(let payload):
            if case .string(let status) = payload["status"] {
                isRecording = status == "on" || status == "processing"
            }
        case .connectionQualityLevel(let digital, let summary, _):
            quality = summary.isEmpty ? "level \(digital)" : summary
        case .audioLevels:
            rebuildTiles()
        case .raw(let name, let payload):
            applyRaw(name, payload)
        default:
            break
        }
    }

    private func loadPollsSupport() {
        guard let room = conference else { return }
        Task {
            pollsSupported = await room.pollsSupported()
        }
    }

    private func applyRaw(_ name: String, _ payload: JSONValue) {
        switch name {
        case "pollReceived":
            guard let id = payload["pollId"]?.stringValue,
                  let question = payload["question"]?.stringValue,
                  !polls.contains(where: { $0.id == id }) else { return }
            let answers = payload["answers"]?.arrayValue
                .compactMap { $0.stringValue ?? $0["name"]?.stringValue } ?? []
            guard !answers.isEmpty else { return }
            polls.append(Poll(
                id: id,
                question: question,
                answers: answers,
                isHistory: payload["history"]?.boolValue ?? false,
                counts: Array(repeating: 0, count: answers.count),
                hasAnswered: false
            ))
        case "pollAnswerReceived":
            guard let id = payload["pollId"]?.stringValue,
                  let index = polls.firstIndex(where: { $0.id == id }) else { return }
            let votes = payload["answers"]?.arrayValue.compactMap(\.boolValue) ?? []
            guard votes.count == polls[index].counts.count else { return }
            for (answer, voted) in votes.enumerated() where voted {
                polls[index].counts[answer] += 1
            }
        case "transcriptionStatus":
            transcriptionActive = payload["status"]?.stringValue == "ON"
        default:
            break
        }
    }

    /// Live captions travel as endpoint messages whose `type` says transcription or
    /// translation. Interim results reuse the message id, so the row is replaced rather
    /// than duplicated when the final text lands.
    private func applyCaption(from: ParticipantID?, content: JSONValue) {
        guard let type = content["type"]?.stringValue,
              type == "transcription-result" || type == "translation-result" else { return }
        let text = type == "translation-result"
            ? content["translatedText"]?.stringValue
            : content["transcript"]?.arrayValue.first?["text"]?.stringValue
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let speaker = content["participant"]?["name"]?.stringValue ?? from ?? "?"
        let isInterim = content["is_interim"]?.boolValue ?? false
        let id = content["message_id"]?.stringValue ?? "\(speaker)-interim"
        upsertCaption(Caption(id: id, speaker: speaker, text: text, isInterim: isInterim))
    }

    private func upsertCaption(_ caption: Caption) {
        if let index = captions.firstIndex(where: { $0.id == caption.id }) {
            captions[index] = caption
        } else {
            captions.append(caption)
        }
        // The overlay shows recent context; older lines are no longer useful on a phone.
        if captions.count > 8 {
            captions.removeFirst(captions.count - 8)
        }
    }

    private func rebuildTiles() {
        guard let room = conference else {
            tiles = []
            appliedReceivePolicy = nil
            return
        }
        var rows: [Tile] = []

        // A muted camera keeps its track id (mute only disables transmission), so handing the
        // tile that id would freeze it on the last frame. nil renders the avatar instead.
        // A live screen share takes the local tile over the camera.
        let localVideo = room.localTracks.values
            .first { $0.mediaType == .video && $0.snapshot.videoType == .desktop && !$0.muted }?
            .id
            ?? room.localTracks.values
                .first { $0.mediaType == .video && !$0.muted }?
                .id
        rows.append(Tile(
            id: "local",
            displayName: room.options.userInfo.displayName,
            videoTrackID: localVideo,
            isLocal: true,
            isDominantSpeaker: false,
            raisedHand: isHandRaised,
            audioMuted: isAudioMuted,
            connectionQuality: quality,
            role: room.isModerator ? .moderator : .participant,
            isModerator: room.isModerator,
            avatarURL: room.options.userInfo.avatarURL,
            email: room.options.userInfo.email
        ))

        for participant in room.participants.values.sorted(by: { $0.id < $1.id }) {
            let owned = participant.snapshot.tracks.filter { $0.mediaType == .video }
            let video = owned.first { !$0.muted }?.id
                ?? room.remoteTracks.values.first {
                    $0.owner == participant.id && $0.mediaType == .video && !$0.muted
                }?.id
            let audioMuted = participant.snapshot.tracks.contains { $0.mediaType == .audio && $0.muted }
                || room.remoteTracks.values.contains { $0.owner == participant.id && $0.mediaType == .audio && $0.muted }
            rows.append(Tile(
                id: participant.id,
                displayName: participant.displayName.isEmpty ? "Guest" : participant.displayName,
                videoTrackID: video,
                isLocal: false,
                isDominantSpeaker: room.dominantSpeaker == participant.id,
                raisedHand: participant.raisedHand,
                audioMuted: audioMuted,
                connectionQuality: quality,
                role: participant.role,
                isModerator: participant.isModerator,
                avatarURL: participant.avatarURL,
                email: participant.email
            ))
        }

        // A track can arrive before presence does. Only synthesize a tile for owners with no
        // participant row (and only one per owner): reusing a tile id makes `ForEach` drop
        // one of the cells.
        for track in room.remoteTracks.values
            where track.mediaType == .video
                && room.participants[track.owner] == nil
                && !rows.contains(where: { $0.id == track.owner }) {
            rows.append(Tile(
                id: track.owner,
                displayName: "Guest",
                videoTrackID: track.muted ? nil : track.id,
                isLocal: false,
                isDominantSpeaker: false,
                raisedHand: false,
                audioMuted: false,
                connectionQuality: nil,
                role: .participant,
                isModerator: false,
                avatarURL: nil,
                email: nil
            ))
        }

        tiles = rows
        updateReceivePolicy(gridSize: rows.count)
    }

    /// Scales the receive side with the grid, mirroring what the jitsi-meet client does:
    /// one or two tiles decode at 720p, a four-up grid at 360p, and larger grids at 180p
    /// with at most six forwarded videos. Each step down cuts decoder CPU and bandwidth.
    private func updateReceivePolicy(gridSize: Int) {
        let maxHeight: Int
        let lastN: Int
        if gridSize <= 2 {
            maxHeight = 720
            lastN = 1
        } else if gridSize <= 4 {
            maxHeight = 360
            lastN = gridSize - 1
        } else {
            maxHeight = 180
            lastN = 6
        }
        guard appliedReceivePolicy?.maxHeight != maxHeight || appliedReceivePolicy?.lastN != lastN else {
            return
        }
        appliedReceivePolicy = (maxHeight, lastN)
        Task { [conference] in
            try? await conference?.applyReceivePolicy(maxHeight: maxHeight, lastN: lastN)
        }
    }

    private func syncMutedState(from room: JitsiConference) {
        isAudioMuted = room.localTracks.values.contains { $0.mediaType == .audio && $0.muted }
        isVideoMuted = room.localTracks.values.contains { $0.mediaType == .video && $0.muted }
    }

}
