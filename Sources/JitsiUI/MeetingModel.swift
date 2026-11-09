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
    }

    public struct Line: Identifiable, Equatable {
        public let id = UUID()
        public let author: String
        public let text: String
        public let isPrivate: Bool
    }

    @Published public private(set) var connectionStatus: ConnectionStatus = .idle
    @Published public private(set) var isJoined = false
    @Published public private(set) var tiles: [Tile] = []
    @Published public private(set) var isAudioMuted = false
    @Published public private(set) var isVideoMuted = false
    @Published public private(set) var isRecording = false
    @Published public private(set) var quality: String?
    @Published public private(set) var message: String?
    @Published public private(set) var transcript: [Line] = []

    public private(set) var conference: JitsiConference?

    private let discovery = CaptureCoordinator()
    private var hubSubscription: Subscription?

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

            let room = JitsiConference(options: options)
            conference = room
            room.onStateChange = { [weak self] in
                Task { @MainActor in self?.rebuildTiles() }
            }

            try await engine.connect(connection)
            try await engine.joinConference(options)
            if !capture.isEmpty {
                _ = try await room.capture(capture)
                syncMutedState(from: room)
            }
            rebuildTiles()
        } catch {
            message = error.localizedDescription
        }
    }

    public func leave() async {
        await conference?.leave()
        await JitsiMeet.shared.engine?.disconnect()
        hubSubscription?.unsubscribe()
        hubSubscription = nil
        conference = nil
        isJoined = false
        tiles = []
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

    public func setQuality(_ height: Int) {
        Task {
            do {
                try await JitsiMeet.shared.engine?.setVideoQuality(height)
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

    /// Cameras and microphones, for a device picker.
    public func devices() -> [DeviceDescriptor] {
        discovery.enumerate()
    }

    /// Frames for one track. Each surface gets its own stream, and the backend fan-out
    /// keeps only the newest frame per track.
    public func frames(for trackID: TrackID) -> AsyncStream<VideoPixelFrame> {
        if let engine = JitsiMeet.shared.engine {
            return engine.frameStream(for: trackID)
        }
        return AsyncStream<VideoPixelFrame> { $0.finish() }
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
        case .conferenceLeft(let reason):
            isJoined = false
            message = reason
        case .conferenceFailed(let error):
            isJoined = false
            message = error.localizedDescription
        case .chatMessage(let from, let text, let isPrivate):
            transcript.append(Line(author: from, text: text, isPrivate: isPrivate))
        case .recordingStateChanged(let payload):
            if case .string(let status) = payload["status"] {
                isRecording = status == "on" || status == "processing"
            }
        case .connectionQualityLevel(let digital, let summary, _):
            quality = summary.isEmpty ? "level \(digital)" : summary
        case .audioLevels:
            rebuildTiles()
        default:
            break
        }
    }

    private func rebuildTiles() {
        guard let room = conference else {
            tiles = []
            return
        }
        var rows: [Tile] = []

        let localVideo = room.localTracks.values
            .first { $0.mediaType == .video && !$0.muted }?
            .id ?? room.localTracks.values.first(where: { $0.mediaType == .video })?.id
        rows.append(Tile(
            id: "local",
            displayName: room.options.displayName,
            videoTrackID: localVideo,
            isLocal: true,
            isDominantSpeaker: false,
            raisedHand: false,
            audioMuted: isAudioMuted,
            connectionQuality: quality
        ))

        for participant in room.participants.values.sorted(by: { $0.id < $1.id }) {
            let owned = participant.snapshot.tracks.filter { $0.mediaType == .video }
            let video = owned.first { !$0.muted }?.id
                ?? owned.first?.id
                ?? room.remoteTracks.values.first { $0.owner == participant.id && $0.mediaType == .video }?.id
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
                connectionQuality: quality
            ))
        }

        // A track can arrive before presence does. Only synthesize a tile for owners with no
        // participant row: reusing an existing tile id makes `ForEach` drop one of the cells.
        for track in room.remoteTracks.values
            where track.mediaType == .video
                && room.participants[track.owner] == nil
                && !rows.contains(where: { $0.videoTrackID == track.id }) {
            rows.append(Tile(
                id: track.owner,
                displayName: "Guest",
                videoTrackID: track.id,
                isLocal: false,
                isDominantSpeaker: false,
                raisedHand: false,
                audioMuted: false,
                connectionQuality: nil
            ))
        }

        tiles = rows
    }

    private func syncMutedState(from room: JitsiConference) {
        isAudioMuted = room.localTracks.values.contains { $0.mediaType == .audio && $0.muted }
        isVideoMuted = room.localTracks.values.contains { $0.mediaType == .video && $0.muted }
    }

}
