import Foundation

/// State and operations for the single conference the device is in.
/// Main-actor confined because its snapshots feed the UI directly.
@MainActor
public final class JitsiConference {
    /// Updated by `switchRoom(to:)` when the endpoint moves between rooms on the same
    /// connection; every other option field stays what it was at join time.
    public private(set) var options: ConferenceOptions
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
    public private(set) var e2eeEnabled = false
    /// True when the deployment supports the visitors (listeners) feature.
    public private(set) var visitorsSupported = false
    /// The MUC resource the lib addresses this endpoint by; the local participant is not in
    /// `participants`, so this is how a local property change is recognised.
    public private(set) var localParticipantID: ParticipantID?
    /// Presence properties written by this endpoint. Mirrors `setLocalParticipantProperty`
    /// because the lib keeps them in the presence map behind a per-key getter.
    public private(set) var localParticipantProperties: [String: JSONValue] = [:]
    /// jicofo room properties (`audio-limit-reached`, `bridge-count`, visitor counters…).
    public private(set) var conferenceProperties: [String: JSONValue] = [:]
    public private(set) var lobbyUsers: [ParticipantID: LobbyUser] = [:]
    /// media type -> moderation enabled, mirrored from `AV_MODERATION_CHANGED`.
    public private(set) var avModeration: [AVModerationMediaType: Bool] = [:]
    /// Rooms published by the deployment's `breakout_rooms` component, in its order.
    public private(set) var breakoutRooms: [BreakoutRoom] = []
    public private(set) var breakoutRoomCounter = 0
    public private(set) var breakoutRoomsSupported = false
    public private(set) var canRenameBreakoutRooms = false
    public private(set) var isInBreakoutRoom = false
    /// The main room this breakout room belongs to; nil while in the main room.
    public private(set) var breakoutMainRoomJID: String?

    /// Managers and moderators in the main room can create, rename, remove and move
    /// participants; the component rejects everyone else.
    public var canManageBreakoutRooms: Bool {
        breakoutRoomsSupported && isModerator && !isInBreakoutRoom
    }

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

    /// Data-channel object message. Unlike `sendJSONMessage`, this does not go through the
    /// MUC, so it is delivered only to endpoints currently reachable over the bridge.
    public func sendEndpointMessage(_ payload: JSONValue, to participantID: ParticipantID? = nil) async throws {
        guard let engine = JitsiMeet.shared.engine else { throw JitsiError.engineNotInstalled }
        guard case .object = payload else {
            throw JitsiError.invalidArgument("sendEndpointMessage expects a JSON object")
        }
        try await engine.sendEndpointMessage(payload, to: participantID)
    }

    /// Sends an arbitrary presence command; values become attributes of its `<name>`
    /// extension. This is the general form of the raise-hand/identity mechanism.
    public func sendCommand(_ name: String, values: [String: JSONValue] = [:]) async throws {
        guard let engine = JitsiMeet.shared.engine else { throw JitsiError.engineNotInstalled }
        guard !name.isEmpty else { throw JitsiError.invalidArgument("command name is required") }
        try await engine.sendCommand(name, values: values)
    }

    /// Sends a command once, then removes it so later presences do not repeat it.
    public func sendCommandOnce(_ name: String, values: [String: JSONValue] = [:]) async throws {
        guard let engine = JitsiMeet.shared.engine else { throw JitsiError.engineNotInstalled }
        guard !name.isEmpty else { throw JitsiError.invalidArgument("command name is required") }
        try await engine.sendCommandOnce(name, values: values)
    }

    public func removeCommand(_ name: String) async throws {
        guard let engine = JitsiMeet.shared.engine else { throw JitsiError.engineNotInstalled }
        try await engine.removeCommand(name)
    }

    /// Starts listening for a presence command; deliveries arrive as `.commandReceived`.
    public func addCommandListener(_ name: String) async throws {
        guard let engine = JitsiMeet.shared.engine else { throw JitsiError.engineNotInstalled }
        try await engine.addCommandListener(name)
    }

    public func removeCommandListener(_ name: String) async throws {
        guard let engine = JitsiMeet.shared.engine else { throw JitsiError.engineNotInstalled }
        try await engine.removeCommandListener(name)
    }

    /// XEP-0459 reaction. `messageID` names the chat message to attach to, or pass "" to
    /// send a standalone reaction.
    public func sendReaction(_ reaction: String, messageID: String = "", to participantID: ParticipantID? = nil) async throws {
        guard let engine = JitsiMeet.shared.engine else { throw JitsiError.engineNotInstalled }
        guard !reaction.isEmpty else { throw JitsiError.invalidArgument("reaction is required") }
        try await engine.sendReaction(reaction, messageID: messageID, to: participantID)
    }

    public func setDisplayName(_ name: String) async throws {
        guard let engine = JitsiMeet.shared.engine else { throw JitsiError.engineNotInstalled }
        try await engine.setDisplayName(name)
    }

    public func raiseHand(_ raised: Bool) async throws {
        guard let engine = JitsiMeet.shared.engine else { throw JitsiError.engineNotInstalled }
        try await engine.raiseHand(raised)
        if raised {
            localParticipantProperties["raiseHand"] = .bool(true)
        } else {
            localParticipantProperties["raiseHand"] = nil
        }
        notify()
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

    // MARK: - Local participant properties

    /// Publishes a `jitsi_participant_<name>` presence property. Values may be strings,
    /// numbers, booleans or arrays of strings, matching lib-jitsi-meet's
    /// `string | string[]` contract (the mirror keeps arrays intact; the lib getter would not).
    public func setLocalParticipantProperty(_ name: String, value: JSONValue) async throws {
        guard let engine = JitsiMeet.shared.engine else { throw JitsiError.engineNotInstalled }
        try await engine.setLocalParticipantProperty(name, value: value)
        localParticipantProperties[name] = value
        notify()
    }

    public func removeLocalParticipantProperty(_ name: String) async throws {
        guard let engine = JitsiMeet.shared.engine else { throw JitsiError.engineNotInstalled }
        try await engine.removeLocalParticipantProperty(name)
        localParticipantProperties[name] = nil
        notify()
    }

    public func localParticipantProperty(_ name: String) async throws -> JSONValue? {
        guard let engine = JitsiMeet.shared.engine else { throw JitsiError.engineNotInstalled }
        return try await engine.localParticipantProperty(name)
    }

    // MARK: - Lobby moderation

    public func approveLobbyUser(_ participantID: ParticipantID) async throws {
        guard let engine = JitsiMeet.shared.engine else { throw JitsiError.engineNotInstalled }
        try await engine.approveLobbyUser(participantID)
    }

    public func denyLobbyUser(_ participantID: ParticipantID) async throws {
        guard let engine = JitsiMeet.shared.engine else { throw JitsiError.engineNotInstalled }
        try await engine.denyLobbyUser(participantID)
    }

    /// Sends a structured lobby message. Passing nil broadcasts to every moderator.
    public func sendLobbyMessage(_ message: JSONValue, to participantID: ParticipantID? = nil) async throws {
        guard let engine = JitsiMeet.shared.engine else { throw JitsiError.engineNotInstalled }
        guard case .object = message else {
            throw JitsiError.invalidArgument("sendLobbyMessage expects a JSON object")
        }
        try await engine.sendLobbyMessage(message, to: participantID)
    }

    /// The id private lobby messages are addressed to; nil when this endpoint is not in the
    /// lobby (moderators in the main room get their id only while waiting).
    public func myLobbyUserID() async throws -> ParticipantID? {
        guard let engine = JitsiMeet.shared.engine else { throw JitsiError.engineNotInstalled }
        return try await engine.myLobbyUserID()
    }

    // MARK: - AV moderation

    public func isAVModerationSupported() async -> Bool {
        (try? await JitsiMeet.shared.engine?.isAVModerationSupported()) ?? false
    }

    public func enableAVModeration(_ mediaType: AVModerationMediaType) async throws {
        guard let engine = JitsiMeet.shared.engine else { throw JitsiError.engineNotInstalled }
        try await engine.enableAVModeration(mediaType)
    }

    public func disableAVModeration(_ mediaType: AVModerationMediaType) async throws {
        guard let engine = JitsiMeet.shared.engine else { throw JitsiError.engineNotInstalled }
        try await engine.disableAVModeration(mediaType)
    }

    public func approveAVModeration(_ participantID: ParticipantID, mediaType: AVModerationMediaType) async throws {
        guard let engine = JitsiMeet.shared.engine else { throw JitsiError.engineNotInstalled }
        try await engine.approveAVModeration(participantID, mediaType: mediaType)
    }

    public func rejectAVModeration(_ participantID: ParticipantID, mediaType: AVModerationMediaType) async throws {
        guard let engine = JitsiMeet.shared.engine else { throw JitsiError.engineNotInstalled }
        try await engine.rejectAVModeration(participantID, mediaType: mediaType)
    }

    public func isAVModerationEnabled(_ mediaType: AVModerationMediaType) -> Bool {
        avModeration[mediaType] ?? false
    }

    // MARK: - Breakout rooms

    /// Re-reads capability flags and the room list. The component also pushes
    /// `BREAKOUT_ROOMS_UPDATED`, so this is only needed before showing a moderator UI.
    @discardableResult
    public func refreshBreakoutRooms() async -> BreakoutRoomsState? {
        guard let engine = JitsiMeet.shared.engine,
              let state = try? await engine.breakoutRoomsState()
        else { return nil }
        applyBreakoutRooms(state)
        return state
    }

    /// Throws when the deployment published no breakout component or this endpoint is not
    /// a moderator; the lib would otherwise log and no-op.
    public func createBreakoutRoom(subject: String) async throws {
        guard let engine = JitsiMeet.shared.engine else { throw JitsiError.engineNotInstalled }
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw JitsiError.invalidArgument("a breakout room needs a subject")
        }
        try await engine.createBreakoutRoom(subject: trimmed)
    }

    /// Renaming needs the component's `rename` feature; `canRenameBreakoutRooms` reports it.
    public func renameBreakoutRoom(_ roomJID: String, subject: String) async throws {
        guard let engine = JitsiMeet.shared.engine else { throw JitsiError.engineNotInstalled }
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw JitsiError.invalidArgument("a breakout room needs a subject")
        }
        try await engine.renameBreakoutRoom(roomJID, subject: trimmed)
    }

    public func removeBreakoutRoom(_ roomJID: String) async throws {
        guard let engine = JitsiMeet.shared.engine else { throw JitsiError.engineNotInstalled }
        guard !roomJID.isEmpty else {
            throw JitsiError.invalidArgument("a breakout room JID is required")
        }
        try await engine.removeBreakoutRoom(roomJID)
    }

    public func sendParticipant(_ participantID: ParticipantID, toBreakoutRoom roomJID: String) async throws {
        guard let engine = JitsiMeet.shared.engine else { throw JitsiError.engineNotInstalled }
        guard !roomJID.isEmpty else {
            throw JitsiError.invalidArgument("a breakout room JID is required")
        }
        try await engine.sendParticipant(participantID, toBreakoutRoom: roomJID)
    }

    /// Moves this endpoint to another room on the same connection. The connection, local
    /// tracks and audio session survive; the engine re-adds the tracks to the new room.
    public func switchRoom(to options: ConferenceOptions) async throws {
        guard let engine = JitsiMeet.shared.engine else { throw JitsiError.engineNotInstalled }
        try await engine.switchConference(to: options)
        self.options = options
        joined = true
        isMediaInterrupted = false
        notify()
        await refreshServerState()
    }

    /// Addresses the room by the JID the component published. lib-jitsi-meet builds the MUC
    /// JID from `name@customDomain`, so the split is not optional.
    public func switchToRoom(atJID roomJID: String) async throws {
        try await switchRoom(to: try options.room(atJID: roomJID))
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
            localParticipantID = nil
            localParticipantProperties = [:]
            conferenceProperties = [:]
            lobbyUsers = [:]
            avModeration = [:]
            e2eeEnabled = false
            visitorsSupported = false
            breakoutRooms = []
            breakoutRoomCounter = 0
            breakoutRoomsSupported = false
            canRenameBreakoutRooms = false
            isInBreakoutRoom = false
            breakoutMainRoomJID = nil
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
        case .participantPropertyChanged(let id, let key, let value, _):
            if id == localParticipantID {
                if case .null = value {
                    localParticipantProperties[key] = nil
                } else {
                    localParticipantProperties[key] = value
                }
                break
            }
            guard var updated = participants[id]?.snapshot else { break }
            if case .null = value {
                updated.properties[key] = nil
            } else {
                updated.properties[key] = value
            }
            participants[id]?.apply(updated)
        case .conferencePropertiesChanged(let properties):
            if case .object(let entries) = properties {
                conferenceProperties = entries
            }
        case .connectionPropertiesUpdated:
            // Connection state belongs to `JitsiConnection`, not the room.
            break
        case .lobbyUserJoined(let user), .lobbyUserUpdated(let user):
            lobbyUsers[user.id] = user
        case .lobbyUserLeft(let id):
            lobbyUsers[id] = nil
        case .avModerationChanged(let enabled, let mediaType, _):
            if let mediaType {
                avModeration[mediaType] = enabled
            }
        case .avModerationApproved(let mediaType):
            avModeration[mediaType] = true
        case .avModerationRejected(let mediaType):
            avModeration[mediaType] = false
        case .avModerationParticipantApproved(_, let mediaType):
            avModeration[mediaType] = true
        case .avModerationParticipantRejected(_, let mediaType):
            avModeration[mediaType] = false
        case .lockStateChanged(let locked):
            isLocked = locked
        case .breakoutRoomsUpdated(let state):
            applyBreakoutRooms(state)
        case .breakoutRoomsMoveToRoom:
            // The move is app-level: `MeetingModel` switches rooms and re-applies mute
            // state; the conference mirror only changes once the new room joins.
            break
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
        e2eeEnabled = state["e2eeEnabled"]?.boolValue ?? false
        visitorsSupported = state["visitorsSupported"]?.boolValue ?? false
        if let id = state["myUserId"]?.stringValue, !id.isEmpty {
            localParticipantID = id
        }
        if case .object(let properties) = state["localParticipantProperties"] {
            localParticipantProperties = properties
        }
        if case .object(let properties) = state["conferenceProperties"] {
            conferenceProperties = properties
        }
        if case .array(let users) = state["lobbyUsers"] {
            var merged: [ParticipantID: LobbyUser] = [:]
            for entry in users {
                guard let id = entry["id"]?.stringValue else { continue }
                merged[id] = LobbyUser(
                    id: id,
                    displayName: entry["displayName"]?.stringValue ?? "",
                    email: entry["email"]?.stringValue,
                    avatarURL: entry["avatarURL"]?.stringValue
                )
            }
            lobbyUsers = merged
        }
        if case .object(let moderation) = state["avModeration"] {
            for (key, value) in moderation {
                if let type = AVModerationMediaType(rawValue: key) {
                    avModeration[type] = value.boolValue ?? false
                }
            }
        }
        if let policy = state["startMutedPolicy"], case .object = policy {
            startMutedPolicy = StartMutedPolicy(
                audio: policy["audio"]?.boolValue ?? false,
                video: policy["video"]?.boolValue ?? false
            )
        }
        if let breakout = state["breakoutRooms"] {
            applyBreakoutRooms(decodeBreakoutRooms(breakout))
        }
        notify()
    }

    private func decodeBreakoutRooms(_ value: JSONValue) -> BreakoutRoomsState {
        BreakoutRoomsState(
            isSupported: value["isSupported"]?.boolValue ?? false,
            canRename: value["canRename"]?.boolValue ?? false,
            isBreakoutRoom: value["isBreakoutRoom"]?.boolValue ?? false,
            mainRoomJID: value["mainRoomJID"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 },
            rooms: (value["rooms"]?.arrayValue ?? []).compactMap { entry in
                guard let jid = entry["jid"]?.stringValue, !jid.isEmpty else { return nil }
                return BreakoutRoom(
                    id: entry["id"]?.stringValue ?? "",
                    jid: jid,
                    name: entry["name"]?.stringValue ?? "",
                    isMainRoom: entry["isMainRoom"]?.boolValue ?? false,
                    participants: (entry["participants"]?.arrayValue ?? []).compactMap { peer in
                        guard let peerJID = peer["jid"]?.stringValue, !peerJID.isEmpty else { return nil }
                        return BreakoutRoomParticipant(
                            jid: peerJID,
                            displayName: peer["displayName"]?.stringValue ?? "",
                            role: ParticipantRole(rawValue: peer["role"]?.stringValue ?? "")
                                ?? .participant
                        )
                    }
                )
            },
            roomCounter: Int(value["roomCounter"]?.doubleValue ?? 0)
        )
    }

    private func applyBreakoutRooms(_ state: BreakoutRoomsState) {
        breakoutRoomsSupported = state.isSupported
        canRenameBreakoutRooms = state.canRename
        isInBreakoutRoom = state.isBreakoutRoom
        breakoutMainRoomJID = state.mainRoomJID
        breakoutRooms = state.rooms
        breakoutRoomCounter = state.roomCounter
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
