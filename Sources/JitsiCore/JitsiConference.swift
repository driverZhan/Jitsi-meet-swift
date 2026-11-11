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
    /// True while ICE is retrying after the media path dropped. The conference stays
    /// joined; lib-jitsi-meet restores the P2P link or falls back to the bridge.
    public private(set) var isMediaInterrupted = false
    /// Server-side flags, refreshed on join and after lobby changes.
    public private(set) var isModerator = false
    public private(set) var lobbySupported = false
    public private(set) var lobbyEnabled = false
    public private(set) var authRequired = false
    public private(set) var passwordRequired = false
    /// Whether the room currently has a password. Tracked from `LOCK_STATE_CHANGED` because
    /// the lib exposes no getter; `lock()`/`unlock()` also refresh it.
    public private(set) var isLocked = false
    /// False when the deployment has no end-conference component, so `end()` would fail.
    public private(set) var canEndConference = false
    /// Who starts muted on join, as published by the room.
    public private(set) var startMutedPolicy: StartMutedPolicy?

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
        isMediaInterrupted = false
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

    /// Receiver-side quality for the current grid: caps forwarded video height and the
    /// number of forwarded remote videos. The bridge honours both hints per endpoint.
    public func applyReceivePolicy(maxHeight: Int, lastN: Int) async throws {
        guard let engine = JitsiMeet.shared.engine else { throw JitsiError.engineNotInstalled }
        try await engine.applyReceivePolicy(maxHeight: maxHeight, lastN: lastN)
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
        guard let engine = JitsiMeet.shared.engine else { throw JitsiError.engineNotInstalled }
        let deviceID = try await engine.switchCamera()
        for (id, track) in localTracks where track.mediaType == .video {
            var updated = track.snapshot
            updated.deviceID = deviceID
            localTracks[id] = LocalTrack(id: id, snapshot: updated, state: track.state)
        }
        notify()
    }

    /// Formats the live camera supports and the resolution/frame rate it is producing now.
    public func videoCapabilities() async throws -> VideoTrackCapabilities {
        guard let engine = JitsiMeet.shared.engine else { throw JitsiError.engineNotInstalled }
        return try await engine.videoCapabilities(for: try cameraTrackID())
    }

    /// Changes capture resolution/frame rate without recreating the track, so the sender
    /// keeps its transceiver and no renegotiation is needed.
    @discardableResult
    public func applyVideoConstraints(_ constraints: VideoConstraints) async throws -> VideoTrackCapabilities {
        guard let engine = JitsiMeet.shared.engine else { throw JitsiError.engineNotInstalled }
        return try await engine.applyVideoConstraints(constraints, to: try cameraTrackID())
    }

    private func cameraTrackID() throws -> TrackID {
        guard let track = localTracks.first(where: {
            $0.value.mediaType == .video && $0.value.snapshot.videoType != .desktop
        }) else {
            throw JitsiError.noLocalTrack(.video)
        }
        return track.key
    }

    /// Starts a desktop track. Frames come from the ReplayKit broadcast extension, so the
    /// returned track is live only after the user starts the system broadcast; use
    /// `ScreenShareBroadcastPicker` to offer that control.
    @discardableResult
    public func startScreenShare() async throws -> LocalTrack {
        guard let engine = JitsiMeet.shared.engine else { throw JitsiError.engineNotInstalled }
        let snapshot = try await engine.startScreenShare()
        let track = LocalTrack(id: snapshot.id, snapshot: snapshot, state: .live)
        localTracks[track.id] = track
        try await engine.attachTracks([track.id])
        notify()
        return track
    }

    public func stopScreenShare() async {
        guard let engine = JitsiMeet.shared.engine else { return }
        let shared = localTracks.values.filter { $0.snapshot.videoType == .desktop }
        for track in shared {
            try? await engine.detachTracks([track.id])
            localTracks[track.id] = nil
        }
        await engine.stopScreenShare()
        notify()
    }

    // MARK: - Signaling

    public func sendChatMessage(_ text: String, to participantID: ParticipantID? = nil) async throws {
        guard let engine = JitsiMeet.shared.engine else { throw JitsiError.engineNotInstalled }
        try await engine.sendMessage(text, to: participantID)
    }

    /// Structured `json-message` payload. jitsi-meet clients receive it as an object rather
    /// than chat text; the top level must be an object so it can carry a `type` discriminator.
    public func sendJSONMessage(_ payload: JSONValue, to participantID: ParticipantID? = nil) async throws {
        guard let engine = JitsiMeet.shared.engine else { throw JitsiError.engineNotInstalled }
        guard case .object = payload else {
            throw JitsiError.invalidArgument("sendJSONMessage expects a JSON object")
        }
        try await engine.sendJSONMessage(payload, to: participantID)
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

    /// Stops or resumes receiving remote audio on this device. Affects nobody else.
    public func setRemoteAudioMuted(_ muted: Bool) async throws {
        guard let engine = JitsiMeet.shared.engine else { throw JitsiError.engineNotInstalled }
        try await engine.setRemoteAudioMuted(muted)
    }

    // MARK: - Conference control

    /// Ends the room for everyone. Check `canEndConference` first; a deployment without the
    /// end-conference component rejects the call.
    public func end() async throws {
        guard let engine = JitsiMeet.shared.engine else { throw JitsiError.engineNotInstalled }
        try await engine.endConference()
    }

    /// Sets or replaces the room password. Only a moderator may call it.
    public func lock(password: String) async throws {
        guard let engine = JitsiMeet.shared.engine else { throw JitsiError.engineNotInstalled }
        try await engine.lockConference(password: password)
        await refreshServerState()
    }

    public func unlock() async throws {
        guard let engine = JitsiMeet.shared.engine else { throw JitsiError.engineNotInstalled }
        try await engine.unlockConference()
        await refreshServerState()
    }

    public func grantOwner(_ participantID: ParticipantID) async throws {
        guard let engine = JitsiMeet.shared.engine else { throw JitsiError.engineNotInstalled }
        try await engine.grantOwner(participantID)
    }

    /// Pass the local participant id to resign as moderator.
    public func revokeOwner(_ participantID: ParticipantID) async throws {
        guard let engine = JitsiMeet.shared.engine else { throw JitsiError.engineNotInstalled }
        try await engine.revokeOwner(participantID)
    }

    /// Marks this endpoint as having joined without audio; peers skip the join chime.
    public func setSilent(_ silent: Bool) async throws {
        guard let engine = JitsiMeet.shared.engine else { throw JitsiError.engineNotInstalled }
        try await engine.setSilent(silent)
    }

    public func setSubject(_ subject: String) async throws {
        guard let engine = JitsiMeet.shared.engine else { throw JitsiError.engineNotInstalled }
        try await engine.setSubject(subject)
    }

    /// Moderators publish the policy every client reads when it starts capturing.
    public func setStartMutedPolicy(audio: Bool, video: Bool) async throws {
        guard let engine = JitsiMeet.shared.engine else { throw JitsiError.engineNotInstalled }
        try await engine.setStartMutedPolicy(StartMutedPolicy(audio: audio, video: video))
        await refreshServerState()
    }

    // MARK: - Lobby

    public func enableLobby() async throws {
        guard let engine = JitsiMeet.shared.engine else { throw JitsiError.engineNotInstalled }
        try await engine.enableLobby()
        await refreshServerState()
    }

    public func disableLobby() async throws {
        guard let engine = JitsiMeet.shared.engine else { throw JitsiError.engineNotInstalled }
        try await engine.disableLobby()
        await refreshServerState()
    }

    /// Joins the waiting room. Only meaningful when the room is members-only and the
    /// local user is not a moderator.
    public func joinLobby(displayName: String, email: String = "") async throws {
        guard let engine = JitsiMeet.shared.engine else { throw JitsiError.engineNotInstalled }
        try await engine.joinLobby(displayName: displayName, email: email)
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

    // MARK: - Polls

    public func pollsSupported() async -> Bool {
        (try? await JitsiMeet.shared.engine?.pollsSupported()) ?? false
    }

    /// Creates a multi-choice poll. Results arrive through the event hub.
    public func createPoll(question: String, answers: [String]) async throws {
        guard let engine = JitsiMeet.shared.engine else { throw JitsiError.engineNotInstalled }
        let trimmed = answers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, trimmed.count >= 2 else {
            throw JitsiError.unsupported("a poll needs a question and at least two answers")
        }
        try await engine.createPoll(id: UUID().uuidString, question: question, answers: trimmed)
    }

    /// `answers` is positional and must match the poll's answer list.
    public func answerPoll(_ id: String, answers: [Bool]) async throws {
        guard let engine = JitsiMeet.shared.engine else { throw JitsiError.engineNotInstalled }
        try await engine.answerPoll(id: id, answers: answers)
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
            Task { await refreshServerState() }
        case .conferenceLeft:
            joined = false
            isMediaInterrupted = false
            isLocked = false
            canEndConference = false
        case .connectionInterrupted:
            isMediaInterrupted = true
        case .connectionRestored:
            isMediaInterrupted = false
        case .participantJoined(let snapshot):
            var merged = snapshot
            if let known = participants[snapshot.id]?.snapshot {
                if !known.tracks.isEmpty {
                    merged.tracks = known.tracks
                }
                // Command presence and the participant snapshot are separate events; keep
                // identity already learned if this is a re-announcement.
                merged.avatarURL = merged.avatarURL ?? known.avatarURL
                merged.email = merged.email ?? known.email
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
        case .participantAvatarChanged(let id, let avatarURL):
            if var updated = participants[id]?.snapshot {
                updated.avatarURL = avatarURL
                participants[id]?.apply(updated)
            }
        case .participantEmailChanged(let id, let email):
            if var updated = participants[id]?.snapshot {
                updated.email = email
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
        case .lockStateChanged(let locked):
            isLocked = locked
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
            applyMute(snapshot.mediaType, muted: snapshot.muted, to: remoteTracks[snapshot.id]?.owner)
        case .participantMuted(let id, let mediaType, let muted):
            // The lib reports this per participant alongside the track event; when the track
            // id it carries is one we never saw (e.g. a source name re-created on unmute),
            // this is the only signal that the participant's mute state changed.
            applyMute(mediaType, muted: muted, to: id)
        default:
            break
        }
        notify()
    }

    private func applyMute(_ mediaType: MediaType, muted: Bool, to owner: ParticipantID?) {
        guard let owner else { return }
        if var updated = participants[owner]?.snapshot {
            var changed = false
            for index in updated.tracks.indices
                where updated.tracks[index].mediaType == mediaType && updated.tracks[index].muted != muted
            {
                updated.tracks[index].muted = muted
                changed = true
            }
            if changed {
                participants[owner]?.apply(updated)
            }
        }
        for (id, track) in remoteTracks
            where track.owner == owner && track.snapshot.mediaType == mediaType && track.muted != muted
        {
            var snapshot = track.snapshot
            snapshot.muted = muted
            remoteTracks[id] = RemoteTrack(snapshot: snapshot, owner: owner, muted: muted)
        }
    }

    private func notify() {
        onStateChange?()
    }

    private func refreshServerState() async {
        guard let engine = JitsiMeet.shared.engine,
              let state = try? await engine.conferenceState()
        else { return }
        isModerator = state["isModerator"]?.boolValue ?? false
        lobbySupported = state["lobbySupported"]?.boolValue ?? false
        lobbyEnabled = state["lobbyEnabled"]?.boolValue ?? false
        authRequired = state["authRequired"]?.boolValue ?? false
        passwordRequired = state["passwordRequired"]?.boolValue ?? false
        isLocked = state["isLocked"]?.boolValue ?? isLocked
        canEndConference = state["endConferenceSupported"]?.boolValue ?? false
        if let policy = state["startMutedPolicy"], case .object = policy {
            startMutedPolicy = StartMutedPolicy(
                audio: policy["audio"]?.boolValue ?? false,
                video: policy["video"]?.boolValue ?? false
            )
        }
        notify()
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
