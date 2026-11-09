import Foundation

/// State and operations for the single conference the device is in.
/// Main-actor confined because its snapshots feed the UI directly.
@MainActor
public final class JitsiConference {
    public let options: ConferenceOptions
    public private(set) var joined = false
    public private(set) var participants: [ParticipantID: JitsiParticipant] = [:]
    public private(set) var localTracks: [TrackID: LocalTrack] = [:]
    public private(set) var remoteTracks: [TrackID: RemoteTrack] = [:]
    public private(set) var dominantSpeaker: ParticipantID?

    /// Emitted after every state mutation so the UI can invalidate once per event.
    public var onStateChange: (() -> Void)?

    private var subscription: Subscription?

    public init(options: ConferenceOptions) {
        self.options = options
        startObserving()
    }

    deinit {
        subscription?.unsubscribe()
    }

    // MARK: - Lifecycle

    public func leave() async {
        await JitsiMeet.shared.engine?.leaveConference()
        joined = false
    }

    // MARK: - Media

    @discardableResult
    public func capture(_ mediaTypes: [MediaType], deviceIDs: [String: String] = [:]) async throws -> [LocalTrack] {
        guard let engine = JitsiMeet.shared.engine else { throw JitsiError.engineNotInstalled }
        let snapshots = try await engine.openCapture(mediaTypes, deviceIDs: deviceIDs)
        var added: [LocalTrack] = []
        for snapshot in snapshots {
            let track = LocalTrack(id: snapshot.id, snapshot: snapshot, state: .live)
            localTracks[track.id] = track
            added.append(track)
        }
        try await engine.attachTracks(snapshots.map(\.id))
        notify()
        return added
    }

    public func addExistingTracks(_ trackIDs: [TrackID]) async throws {
        guard let engine = JitsiMeet.shared.engine else { throw JitsiError.engineNotInstalled }
        try await engine.attachTracks(trackIDs)
    }

    public func removeTrack(_ trackID: TrackID) async throws {
        guard let engine = JitsiMeet.shared.engine else { throw JitsiError.engineNotInstalled }
        try await engine.detachTracks([trackID])
        localTracks[trackID] = nil
        notify()
    }

    public func setMuted(_ muted: Bool, mediaType: MediaType) async throws {
        guard let engine = JitsiMeet.shared.engine else { throw JitsiError.engineNotInstalled }
        try await engine.setMuted(muted, mediaType: mediaType)
        for (id, track) in localTracks where track.mediaType == mediaType {
            var updated = track.snapshot
            updated.muted = muted
            localTracks[id] = LocalTrack(id: id, snapshot: updated, state: muted ? .muted : .live)
        }
        notify()
    }

    public func switchCamera() async throws {
        // Requires the front/back device list from AVCaptureDevice; wired through
        // JitsiMedia.CaptureCoordinator once the track is live.
        throw JitsiError.unsupported("switchCamera")
    }

    // MARK: - Signaling

    public func sendChatMessage(_ text: String, to participantID: ParticipantID? = nil) async throws {
        guard let engine = JitsiMeet.shared.engine else { throw JitsiError.engineNotInstalled }
        try await engine.sendMessage(text, to: participantID)
    }

    public func setDisplayName(_ name: String) async throws {
        guard let engine = JitsiMeet.shared.engine else { throw JitsiError.engineNotInstalled }
        try await engine.setDisplayName(name)
    }

    public func raiseHand(_ raised: Bool) async throws {
        guard let engine = JitsiMeet.shared.engine else { throw JitsiError.engineNotInstalled }
        try await engine.raiseHand(raised)
    }

    public func kick(_ participantID: ParticipantID) async throws {
        guard let engine = JitsiMeet.shared.engine else { throw JitsiError.engineNotInstalled }
        try await engine.kick(participantID)
    }

    public func mute(_ participantID: ParticipantID, mediaType: MediaType) async throws {
        guard let engine = JitsiMeet.shared.engine else { throw JitsiError.engineNotInstalled }
        try await engine.muteRemote(participantID, mediaType: mediaType, mute: true)
    }

    // MARK: - Sessions

    public func startRecording(_ options: RecordingOptions) async throws {
        guard let engine = JitsiMeet.shared.engine else { throw JitsiError.engineNotInstalled }
        try await engine.startRecording(options)
    }

    public func stopRecording() async throws {
        guard let engine = JitsiMeet.shared.engine else { throw JitsiError.engineNotInstalled }
        try await engine.stopRecording()
    }

    public func enableE2EE(key: String, password: String? = nil) async throws {
        guard let engine = JitsiMeet.shared.engine else { throw JitsiError.engineNotInstalled }
        try await engine.enableE2EE(key: key, password: password)
    }

    public func disableE2EE() async throws {
        guard let engine = JitsiMeet.shared.engine else { throw JitsiError.engineNotInstalled }
        try await engine.disableE2EE()
    }

    // MARK: - Reduction

    private func startObserving() {
        subscription = JitsiMeet.shared.events.subscribe { [weak self] event in
            guard let self else { return }
            Task { @MainActor in self.reduce(event) }
        }
    }

    private func reduce(_ event: MeetingEvent) {
        switch event {
        case .conferenceJoined:
            joined = true
        case .conferenceLeft:
            joined = false
        case .participantJoined(let snapshot):
            var merged = snapshot
            if let known = participants[snapshot.id]?.snapshot.tracks, !known.isEmpty {
                merged.tracks = known
            }
            participants[snapshot.id] = JitsiParticipant(snapshot: merged)
        case .participantLeft(let snapshot):
            participants[snapshot.id] = nil
            for (id, track) in remoteTracks where track.owner == snapshot.id {
                remoteTracks[id] = nil
            }
        case .participantDisplayNameChanged(let id, let name):
            if var updated = participants[id]?.snapshot {
                updated.displayName = name
                participants[id]?.apply(updated)
            }
        case .participantRoleChanged(let id, let role):
            if var updated = participants[id]?.snapshot {
                updated.role = role
                participants[id]?.apply(updated)
            }
        case .dominantSpeakerChanged(let id):
            dominantSpeaker = id
        case .raisedHandChanged(let id, let raised):
            guard let existing = participants[id]?.snapshot else { break }
            var updated = existing
            updated.raisedHand = raised
            participants[id]?.apply(updated)
        case .localTrackAdded(let snapshot):
            localTracks[snapshot.id] = LocalTrack(id: snapshot.id, snapshot: snapshot, state: .live)
        case .localTrackRemoved(let snapshot):
            localTracks[snapshot.id] = nil
        case .remoteTrackAdded(let snapshot, let owner):
            remoteTracks[snapshot.id] = RemoteTrack(snapshot: snapshot, owner: owner, muted: snapshot.muted)
            attach(snapshot, to: owner)
        case .remoteTrackRemoved(let snapshot, _):
            remoteTracks[snapshot.id] = nil
            detach(snapshot.id)
        case .trackMuteChanged(let snapshot):
            if let existing = remoteTracks[snapshot.id] {
                remoteTracks[snapshot.id] = RemoteTrack(snapshot: snapshot, owner: existing.owner, muted: snapshot.muted)
            }
            attach(snapshot, to: remoteTracks[snapshot.id]?.owner)
        default:
            break
        }
        notify()
    }

    private func notify() {
        onStateChange?()
    }

    /// The JS layer reports tracks and participants on separate channels, so a participant
    /// snapshot never carries its own tracks. Mirroring them here keeps `participant.tracks`
    /// truthful for any UI that reads participants instead of `remoteTracks`.
    private func attach(_ track: TrackSnapshot, to owner: ParticipantID?) {
        guard let owner, var updated = participants[owner]?.snapshot else { return }
        if let index = updated.tracks.firstIndex(where: { $0.id == track.id }) {
            updated.tracks[index] = track
        } else {
            updated.tracks.append(track)
        }
        participants[owner]?.apply(updated)
    }

    private func detach(_ trackID: TrackID) {
        for (id, participant) in participants {
            guard participant.snapshot.tracks.contains(where: { $0.id == trackID }) else { continue }
            var updated = participant.snapshot
            updated.tracks.removeAll { $0.id == trackID }
            participants[id]?.apply(updated)
        }
    }
}
