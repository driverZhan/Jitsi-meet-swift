import CoreVideo
import JitsiCore

/// Engine stub for tests that exercise the Swift side of the bridge. Frames are synthetic:
/// they prove plumbing, not media.
final class StubEngine: MeetingEngine {
    let events = AsyncStream<MeetingEvent> { $0.finish() }
    private(set) var requestedTrackID: TrackID?
    private(set) var connectCount = 0
    private(set) var disconnectCount = 0
    private(set) var prepareCount = 0
    private(set) var joinCount = 0
    private(set) var appliedVideoConstraints: (constraints: VideoConstraints, trackID: TrackID)?
    private(set) var capabilitiesTrackID: TrackID?
    private(set) var jsonMessages: [(payload: JSONValue, to: ParticipantID?)] = []
    private(set) var endCount = 0
    private(set) var lockPasswords: [String] = []
    private(set) var unlockCount = 0
    private(set) var ownerChanges: [(id: ParticipantID, granted: Bool)] = []
    private(set) var silentValues: [Bool] = []
    private(set) var subjects: [String] = []
    private(set) var startMutedPolicies: [StartMutedPolicy] = []
    private(set) var localPropertyWrites: [(name: String, value: JSONValue)] = []
    private(set) var localPropertyRemovals: [String] = []
    private(set) var localPropertyReads: [String] = []
    private(set) var lobbyApprovals: [ParticipantID] = []
    private(set) var lobbyDenials: [ParticipantID] = []
    private(set) var lobbyMessages: [(message: JSONValue, to: ParticipantID?)] = []
    /// The four AV calls are fired concurrently by the model, so appends need a lock even in a
    /// stub; an unsynchronised array loses entries under the cooperative pool.
    private let avCallLock = NSLock()
    private var avCalls: [(action: String, mediaType: AVModerationMediaType, id: ParticipantID?)] = []
    var avModerationCalls: [(action: String, mediaType: AVModerationMediaType, id: ParticipantID?)] {
        avCallLock.lock()
        defer { avCallLock.unlock() }
        return avCalls
    }
    /// Backing store for `localParticipantProperty(_:)`; tests seed it directly.
    var localPropertyValues: [String: JSONValue] = [:]
    var lobbyUserIDValue: ParticipantID?
    var avModerationSupported = true
    /// Snapshot returned by `conferenceState()`; tests override individual keys.
    var conferenceStateValue = JSONValue.object([:])
    private let pixelBuffer: CVPixelBuffer = {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 64, 48, kCVPixelFormatType_32BGRA, nil, &buffer)
        return buffer!
    }()

    func frameStream(for trackID: TrackID) -> AsyncStream<VideoPixelFrame> {
        requestedTrackID = trackID
        let buffer = pixelBuffer
        return AsyncStream { continuation in
            continuation.yield(VideoPixelFrame(pixelBuffer: buffer, timestampUs: 1234))
            continuation.finish()
        }
    }

    func install() async throws {}
    func dispose() async {}
    func connect(_: ConnectionOptions) async throws { connectCount += 1 }
    func disconnect() async { disconnectCount += 1 }
    func joinConference(_: ConferenceOptions, waitForJoin _: TimeInterval?) async throws { joinCount += 1 }
    func prepareConference(_: ConferenceOptions) async throws { prepareCount += 1 }
    func leaveConference() async {}
    func openCapture(_: [MediaType], deviceIDs _: [String: String]) async throws -> [TrackSnapshot] { [] }
    func closeCapture(_: [TrackID]) async throws {}
    func attachTracks(_: [TrackID]) async throws {}
    func detachTracks(_: [TrackID]) async throws {}
    func setMuted(_: Bool, mediaType: MediaType) async throws {}

    func videoCapabilities(for trackID: TrackID) async throws -> VideoTrackCapabilities {
        capabilitiesTrackID = trackID
        return VideoTrackCapabilities(
            formats: [.init(width: 1920, height: 1080, minFrameRate: 1, maxFrameRate: 30)],
            activeWidth: 1280,
            activeHeight: 720,
            activeFrameRate: 30,
            deviceID: "stub-camera")
    }

    func applyVideoConstraints(
        _ constraints: VideoConstraints,
        to trackID: TrackID
    ) async throws -> VideoTrackCapabilities {
        appliedVideoConstraints = (constraints, trackID)
        return VideoTrackCapabilities(
            formats: [],
            activeWidth: constraints.width ?? 1280,
            activeHeight: constraints.height ?? 720,
            activeFrameRate: Double(constraints.frameRate ?? 30),
            deviceID: "stub-camera")
    }

    func sendMessage(_: String, to _: ParticipantID?) async throws {}

    func sendJSONMessage(_ payload: JSONValue, to participantID: ParticipantID?) async throws {
        jsonMessages.append((payload, participantID))
    }
    func setDisplayName(_: String) async throws {}
    func raiseHand(_: Bool) async throws {}
    func kick(_: ParticipantID) async throws {}
    func muteRemote(_: ParticipantID, mediaType: MediaType, mute: Bool) async throws {}
    func endConference() async throws { endCount += 1 }
    func lockConference(password: String) async throws { lockPasswords.append(password) }
    func unlockConference() async throws { unlockCount += 1 }
    func grantOwner(_ participantID: ParticipantID) async throws {
        ownerChanges.append((participantID, true))
    }
    func revokeOwner(_ participantID: ParticipantID) async throws {
        ownerChanges.append((participantID, false))
    }
    func setSilent(_ silent: Bool) async throws { silentValues.append(silent) }
    func setSubject(_ subject: String) async throws { subjects.append(subject) }
    func setStartMutedPolicy(_ policy: StartMutedPolicy) async throws {
        startMutedPolicies.append(policy)
    }
    func setLocalParticipantProperty(_ name: String, value: JSONValue) async throws {
        localPropertyWrites.append((name, value))
        localPropertyValues[name] = value
    }

    func removeLocalParticipantProperty(_ name: String) async throws {
        localPropertyRemovals.append(name)
        localPropertyValues[name] = nil
    }

    func localParticipantProperty(_ name: String) async throws -> JSONValue? {
        localPropertyReads.append(name)
        return localPropertyValues[name]
    }

    func approveLobbyUser(_ participantID: ParticipantID) async throws {
        lobbyApprovals.append(participantID)
    }

    func denyLobbyUser(_ participantID: ParticipantID) async throws {
        lobbyDenials.append(participantID)
    }

    func sendLobbyMessage(_ message: JSONValue, to participantID: ParticipantID?) async throws {
        lobbyMessages.append((message, participantID))
    }

    func myLobbyUserID() async throws -> ParticipantID? {
        lobbyUserIDValue
    }

    func isAVModerationSupported() async throws -> Bool {
        avModerationSupported
    }

    private func recordAV(
        _ action: String,
        _ mediaType: AVModerationMediaType,
        _ participantID: ParticipantID? = nil
    ) {
        avCallLock.lock()
        avCalls.append((action, mediaType, participantID))
        avCallLock.unlock()
    }

    func enableAVModeration(_ mediaType: AVModerationMediaType) async throws {
        recordAV("enable", mediaType)
    }

    func disableAVModeration(_ mediaType: AVModerationMediaType) async throws {
        recordAV("disable", mediaType)
    }

    func approveAVModeration(_ participantID: ParticipantID, mediaType: AVModerationMediaType) async throws {
        recordAV("approve", mediaType, participantID)
    }

    func rejectAVModeration(_ participantID: ParticipantID, mediaType: AVModerationMediaType) async throws {
        recordAV("reject", mediaType, participantID)
    }

    func conferenceState() async throws -> JSONValue { conferenceStateValue }

    private(set) var createdBreakoutSubjects: [String] = []
    private(set) var renamedBreakoutRooms: [(roomJID: String, subject: String)] = []
    private(set) var removedBreakoutRooms: [String] = []
    private(set) var breakoutMoves: [(participantID: ParticipantID, roomJID: String)] = []
    private(set) var switches: [ConferenceOptions] = []
    var breakoutStateValue = BreakoutRoomsState()

    func breakoutRoomsState() async throws -> BreakoutRoomsState { breakoutStateValue }

    func createBreakoutRoom(subject: String) async throws {
        createdBreakoutSubjects.append(subject)
    }

    func renameBreakoutRoom(_ roomJID: String, subject: String) async throws {
        renamedBreakoutRooms.append((roomJID, subject))
    }

    func removeBreakoutRoom(_ roomJID: String) async throws {
        removedBreakoutRooms.append(roomJID)
    }

    func sendParticipant(_ participantID: ParticipantID, toBreakoutRoom roomJID: String) async throws {
        breakoutMoves.append((participantID, roomJID))
    }

    func switchConference(to options: ConferenceOptions) async throws {
        switches.append(options)
    }

    func startRecording(_: RecordingOptions) async throws {}
    func stopRecording() async throws {}
    func enableE2EE(key _: String, password _: String?) async throws {}
    func disableE2EE() async throws {}
}
