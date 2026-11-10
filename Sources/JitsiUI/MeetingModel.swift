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
    @Published public private(set) var quality: String?
    @Published public private(set) var message: String?
    @Published public private(set) var transcript: [Line] = []
    @Published public private(set) var polls: [Poll] = []
    /// False when the deployment has no Prosody polls component.
    @Published public private(set) var pollsSupported = false
    @Published public private(set) var captions: [Caption] = []
    @Published public private(set) var transcriptionActive = false
    /// CPU, memory, thermal state and first-remote-frame latency; sampling starts on join.
    public let metrics = MeetingMetrics()

    public var isModerator: Bool { conference?.isModerator ?? false }

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
    /// Upstream's `MAX_CONNECTION_RETRIES`: after three failed rejoins the room is gone.
    private static let maxRejoinAttempts = 3

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
        session = nil
        await conference?.leave()
        await JitsiMeet.shared.engine?.disconnect()
        hubSubscription?.unsubscribe()
        hubSubscription = nil
        conference = nil
        isJoined = false
        isHandRaised = false
        tiles = []
        polls = []
        pollsSupported = false
        captions = []
        transcriptionActive = false
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
        room.onStateChange = { [weak self] in
            Task { @MainActor in self?.rebuildTiles() }
        }
        return room
    }

    /// Full rejoin, the same recovery a jitsi-meet browser performs on
    /// `CONNECTION_DROPPED`. The lib has already disposed the local tracks, so capture runs
    /// again and the user's mute choices are re-applied to the new tracks.
    private func performRejoin() async {
        guard let session, let engine = JitsiMeet.shared.engine else { return }
        while rejoinAttempt < Self.maxRejoinAttempts {
            rejoinAttempt += 1
            // Jittered backoff: 1.5s–3s for the first try, growing with each attempt.
            let base = 1.5 * Double(rejoinAttempt)
            let delay = base + Double.random(in: 0...base)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            message = "Reconnecting… (\(rejoinAttempt)/\(Self.maxRejoinAttempts))"

            let room = makeRoom(session.conference)
            await engine.disconnect()
            do {
                try await engine.connect(session.connection)
                try await engine.prepareConference(session.conference)
                if !session.capture.isEmpty {
                    _ = try await room.capture(session.capture)
                    if isAudioMuted { try? await room.setMuted(true, mediaType: .audio) }
                    if isVideoMuted { try? await room.setMuted(true, mediaType: .video) }
                }
                try await engine.joinConference(session.conference)
                rejoinAttempt = 0
                message = nil
                rebuildTiles()
                return
            } catch {
                message = "Reconnect attempt \(rejoinAttempt) failed: \(error.localizedDescription)"
            }
        }
        message = "Connection lost. Leave and rejoin to continue."
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
        case .connectionLost:
            isJoined = false
            metrics.stop()
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
