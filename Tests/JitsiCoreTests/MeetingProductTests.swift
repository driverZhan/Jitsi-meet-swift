import JitsiCore
import JitsiMeetExample
import JitsiUI
import XCTest

/// Poll and caption reduction. Both arrive as unstructured hub events, so the tests
/// publish them directly instead of driving a real conference.
@MainActor
final class MeetingProductTests: XCTestCase {
    private var engine: StubEngine?

    override func setUp() async throws {
        engine = StubEngine()
        JitsiMeet.shared.attach(engine!)
    }

    override func tearDown() async throws {
        engine = nil
        // `MeetingSession.start` spawns a receive-policy task that can still hold the engine
        // past the end of the test method; wait for it to release before asserting.
        for _ in 0..<50 where JitsiMeet.shared.engine != nil {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertNil(JitsiMeet.shared.engine)
    }

    private func joinedModel(_ conference: ConferenceOptions? = nil) async -> MeetingSession {
        let model = MeetingSession()
        await model.start(
            JitsiMeetDemo.connection(host: "meet.example.org"),
            conference: conference ?? JitsiMeetDemo.conference(room: "demo-room", displayName: "Demo"),
            capture: []
        )
        return model
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<300 {
            if predicate() { return }
            await Task.yield()
        }
    }

    /// For assertions that cross the jittered reconnect backoff (1.5–3 s per attempt).
    private func waitUntil(timeout: TimeInterval, _ predicate: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func testPollReceivedThenAnswersAreTallied() async {
        let model = await joinedModel()
        JitsiMeet.shared.events.publish(.raw(name: "pollReceived", .object([
            "pollId": .string("poll-1"),
            "question": .string("Lunch?"),
            "answers": .array([.string("Yes"), .string("No")])
        ])))
        await waitUntil { model.polls.count == 1 }
        XCTAssertEqual(model.polls.first?.question, "Lunch?")
        XCTAssertEqual(model.polls.first?.answers, ["Yes", "No"])

        JitsiMeet.shared.events.publish(.raw(name: "pollAnswerReceived", .object([
            "pollId": .string("poll-1"),
            "answers": .array([.bool(true), .bool(false)])
        ])))
        JitsiMeet.shared.events.publish(.raw(name: "pollAnswerReceived", .object([
            "pollId": .string("poll-1"),
            "answers": .array([.bool(true), .bool(true)])
        ])))
        await waitUntil { model.polls.first?.totalVotes == 2 }
        XCTAssertEqual(model.polls.first?.counts, [2, 1])

        JitsiMeet.shared.events.publish(.raw(name: "pollReceived", .object([
            "pollId": .string("poll-1"),
            "question": .string("Lunch?"),
            "answers": .array([.string("Yes"), .string("No")])
        ])))
        await Task.yield()
        XCTAssertEqual(model.polls.first?.counts, [2, 1], "a replayed poll must not reset local tallies")
    }

    func testMalformedPollAnswerIsIgnored() async {
        let model = await joinedModel()
        JitsiMeet.shared.events.publish(.raw(name: "pollReceived", .object([
            "pollId": .string("poll-1"),
            "question": .string("Lunch?"),
            "answers": .array([.string("Yes"), .string("No")])
        ])))
        await waitUntil { model.polls.count == 1 }

        JitsiMeet.shared.events.publish(.raw(name: "pollAnswerReceived", .object([
            "pollId": .string("poll-1"),
            "answers": .array([.bool(true)])
        ])))
        await Task.yield()
        XCTAssertEqual(model.polls.first?.counts, [0, 0])
    }

    func testInterimCaptionIsReplacedByItsFinalText() async {
        let model = await joinedModel()
        func caption(_ text: String, interim: Bool) -> MeetingEvent {
            .endpointMessage(from: "p1", .object([
                "type": .string("transcription-result"),
                "message_id": .string("m1"),
                "is_interim": .bool(interim),
                "participant": .object(["name": .string("Ada")]),
                "transcript": .array([.object(["text": .string(text)])])
            ]))
        }

        JitsiMeet.shared.events.publish(caption("hello", interim: true))
        await waitUntil { model.captions.count == 1 }
        XCTAssertEqual(model.captions.first?.text, "hello")
        XCTAssertEqual(model.captions.first?.isInterim, true)

        JitsiMeet.shared.events.publish(caption("hello world", interim: false))
        await waitUntil { model.captions.first?.text == "hello world" }
        XCTAssertEqual(model.captions.count, 1, "the final result reuses the interim message id")
        XCTAssertEqual(model.captions.first?.speaker, "Ada")
        XCTAssertEqual(model.captions.first?.isInterim, false)
    }

    func testTranscriptionStatusTogglesTheOverlay() async {
        let model = await joinedModel()
        JitsiMeet.shared.events.publish(.raw(name: "transcriptionStatus", .object(["status": .string("ON")])))
        await waitUntil { model.transcriptionActive }
        JitsiMeet.shared.events.publish(.raw(name: "transcriptionStatus", .object(["status": .string("OFF")])))
        await waitUntil { !model.transcriptionActive }
    }

    func testRaisingHandMarksTheLocalTile() async {
        let model = await joinedModel()
        model.toggleHand()
        await waitUntil { model.isHandRaised }

        XCTAssertEqual(model.tiles.first(where: { $0.isLocal })?.raisedHand, true)
    }

    func testParticipantCallbacksReportJoinMuteAndAudioLevel() async {
        let model = await joinedModel()
        var joined: [MeetingSession.Tile] = []
        var left: [MeetingSession.Tile] = []
        var changes: [(id: String, change: MeetingSession.ParticipantChange)] = []
        var levels: [(id: String, level: Double)] = []
        model.onParticipantJoined = { joined.append($0) }
        model.onParticipantLeft = { left.append($0) }
        model.onParticipantChanged = { changes.append(($0.id, $1)) }
        model.onAudioLevel = { levels.append(($0, $1)) }

        JitsiMeet.shared.events.publish(.participantJoined(ParticipantSnapshot(
            id: "p1",
            displayName: "Ada",
            tracks: [
                TrackSnapshot(id: "p1-audio", mediaType: .audio, isLocal: false),
                TrackSnapshot(id: "p1-video", mediaType: .video, isLocal: false)
            ]
        )))
        await waitUntil { joined.contains { $0.id == "p1" } }
        XCTAssertEqual(joined.first { $0.id == "p1" }?.displayName, "Ada")
        XCTAssertEqual(model.tiles.first { $0.id == "p1" }?.videoMuted, false)

        // Speaking is derived from the level and reported only when it crosses the threshold.
        JitsiMeet.shared.events.publish(.audioLevels(["p1": 0.3]))
        await waitUntil { model.tiles.first { $0.id == "p1" }?.isSpeaking == true }
        XCTAssertEqual(model.audioLevels["p1"] ?? 0, 0.3, accuracy: 0.0001)
        XCTAssertEqual(levels.last?.id, "p1")
        XCTAssertEqual(levels.last?.level ?? 0, 0.3, accuracy: 0.0001)
        XCTAssertTrue(changes.contains { $0.id == "p1" && $0.change.contains(.speakingStarted) })

        JitsiMeet.shared.events.publish(.participantMuted("p1", .audio, true))
        await waitUntil { model.tiles.first { $0.id == "p1" }?.audioMuted == true }
        XCTAssertTrue(changes.contains { $0.id == "p1" && $0.change.contains(.microphoneMuted) })
        XCTAssertEqual(model.tiles.first { $0.id == "p1" }?.isSpeaking, false,
                       "a muted microphone must not keep the speaking ring")

        JitsiMeet.shared.events.publish(.participantLeft(ParticipantSnapshot(id: "p1", displayName: "Ada")))
        await waitUntil { left.contains { $0.id == "p1" } }
        XCTAssertNil(model.audioLevels["p1"], "a departed participant's level is dropped")
        XCTAssertFalse(model.tiles.contains { $0.id == "p1" })
    }

    func testLocalTileCarriesTheConfiguredAvatarAndEmail() async {
        let model = await joinedModel(JitsiMeetDemo.conference(
            room: "demo-room",
            displayName: "Ada",
            email: "ada@example.test",
            avatarURL: "https://example.test/a.png"
        ))
        await waitUntil { model.tiles.contains(where: { $0.isLocal }) }

        XCTAssertEqual(model.tiles.first(where: { $0.isLocal })?.avatarURL, "https://example.test/a.png")
        XCTAssertEqual(model.tiles.first(where: { $0.isLocal })?.email, "ada@example.test")
    }

    func testRemoteAvatarAndEmailArriveThroughPresenceCommands() async {
        let model = await joinedModel()
        JitsiMeet.shared.events.publish(.participantJoined(
            ParticipantSnapshot(id: "p1", displayName: "Ada")
        ))
        await waitUntil { model.tiles.contains { $0.id == "p1" } }

        JitsiMeet.shared.events.publish(.participantAvatarChanged("p1", "https://example.test/a.png"))
        JitsiMeet.shared.events.publish(.participantEmailChanged("p1", "ada@example.test"))
        await waitUntil {
            let tile = model.tiles.first { $0.id == "p1" }
            return tile?.avatarURL == "https://example.test/a.png" && tile?.email == "ada@example.test"
        }
        XCTAssertEqual(model.tiles.first { $0.id == "p1" }?.avatarURL, "https://example.test/a.png")
        XCTAssertEqual(model.tiles.first { $0.id == "p1" }?.email, "ada@example.test")

        // Withdrawing the avatar-url command removes the URL, but leaves the email alone.
        JitsiMeet.shared.events.publish(.participantAvatarChanged("p1", nil))
        await waitUntil { model.tiles.first { $0.id == "p1" }?.avatarURL == nil }
        XCTAssertNil(model.tiles.first { $0.id == "p1" }?.avatarURL)
        XCTAssertEqual(model.tiles.first { $0.id == "p1" }?.email, "ada@example.test")
    }

    /// A server 5xx is not `connection.droppedError`, so the automatic rejoin never fires;
    /// `retryConnection()` is the host's way back into the room.
    func testRetryConnectionRejoinsAfterAServerError() async {
        let model = await joinedModel()
        JitsiMeet.shared.events.publish(.conferenceJoined("demo-room"))
        await waitUntil { model.isJoined }
        JitsiMeet.shared.events.publish(.conferenceFailed(.remote("503 Service Unavailable")))
        await waitUntil { !model.isJoined }
        XCTAssertTrue(model.canRetryConnection)

        let connectsBefore = engine!.connectCount
        model.retryConnection()
        // The connect lands before the rejoin has rejoined, so wait for the whole pass:
        // `message` only clears once the room is up again.
        await waitUntil(timeout: 4) { self.engine?.joinCount == 2 && model.message == nil }
        XCTAssertEqual(engine?.connectCount, connectsBefore + 1)
        XCTAssertEqual(engine?.disconnectCount, 1, "the rejoin tears the old signalling down first")
        XCTAssertEqual(engine?.joinCount, 2, "the rejoin joins the same room again")
        XCTAssertNil(model.message)
        await model.leave()
    }

    /// Coming back from the background grants a fresh quota for a room that is gone.
    func testForegroundAfterBackgroundRetriesADeadSession() async {
        let model = await joinedModel()
        JitsiMeet.shared.events.publish(.conferenceJoined("demo-room"))
        await waitUntil { model.isJoined }
        JitsiMeet.shared.events.publish(.conferenceFailed(.remote("503")))
        await waitUntil { !model.isJoined }

        let connectsBefore = engine!.connectCount
        model.setAppActive(true)
        await Task.yield()
        XCTAssertEqual(engine?.connectCount, connectsBefore, "no background round-trip, no retry")

        model.setAppActive(false)
        model.setAppActive(true)
        await waitUntil(timeout: 4) { self.engine?.connectCount == connectsBefore + 1 }
        XCTAssertEqual(engine?.connectCount, connectsBefore + 1)
        await model.leave()
    }

    func testForegroundLeavesAHealthyCallAlone() async {
        let model = await joinedModel()
        JitsiMeet.shared.events.publish(.conferenceJoined("demo-room"))
        await waitUntil { model.isJoined }

        let connectsBefore = engine!.connectCount
        model.setAppActive(false)
        model.setAppActive(true)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(engine?.connectCount, connectsBefore)
        await model.leave()
    }

    /// The lobby wait and an initial join also have `isJoined == false`; a lifecycle retry
    /// must not fight those flows.
    func testForegroundDoesNotRestartASessionThatNeverJoined() async {
        let model = await joinedModel()
        let connectsBefore = engine!.connectCount
        model.setAppActive(false)
        model.setAppActive(true)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(engine?.connectCount, connectsBefore)
        await model.leave()
    }

    /// Screen share is a second video track; resolution changes must always address the camera.
    func testVideoConstraintsTargetTheCameraWhenScreenShareIsLive() async throws {
        let model = await joinedModel()
        JitsiMeet.shared.events.publish(.localTrackAdded(
            TrackSnapshot(id: "cam", mediaType: .video, isLocal: true, videoType: .camera)))
        JitsiMeet.shared.events.publish(.localTrackAdded(
            TrackSnapshot(id: "screen", mediaType: .video, isLocal: true, videoType: .desktop)))
        await waitUntil { model.conference?.localTracks.count == 2 }

        let conference = try XCTUnwrap(model.conference)
        let applied = try await conference.applyVideoConstraints(
            VideoConstraints(width: 640, height: 480, frameRate: 15))
        XCTAssertEqual(engine?.appliedVideoConstraints?.trackID, "cam")
        XCTAssertEqual(
            engine?.appliedVideoConstraints?.constraints,
            VideoConstraints(width: 640, height: 480, frameRate: 15))
        XCTAssertEqual(applied.activeWidth, 640)
        XCTAssertEqual(applied.activeFrameRate, 15)

        _ = try await conference.videoCapabilities()
        XCTAssertEqual(engine?.capabilitiesTrackID, "cam")
        await model.leave()
    }

    func testMeetingSessionForwardsVideoConstraints() async {
        let model = await joinedModel()
        JitsiMeet.shared.events.publish(.localTrackAdded(
            TrackSnapshot(id: "cam", mediaType: .video, isLocal: true, videoType: .camera)))
        await waitUntil { model.conference?.localTracks["cam"] != nil }

        model.applyVideoConstraints(width: 320, height: 240, frameRate: 10)
        await waitUntil { self.engine?.appliedVideoConstraints != nil }
        XCTAssertEqual(engine?.appliedVideoConstraints?.trackID, "cam")
        XCTAssertEqual(engine?.appliedVideoConstraints?.constraints.width, 320)
        XCTAssertEqual(engine?.appliedVideoConstraints?.constraints.height, 240)
        XCTAssertEqual(engine?.appliedVideoConstraints?.constraints.frameRate, 10)
        await model.leave()
    }

    /// Structured messages must keep the object shape; a bare array would be accepted by
    /// lib-jitsi-meet but is not a valid `json-message` payload for jitsi-meet clients.
    func testStructuredJSONMessageKeepsItsObjectShape() async throws {
        let model = await joinedModel()
        let conference = try XCTUnwrap(model.conference)
        let payload: JSONValue = .object([
            "type": .string("reaction"),
            "emoji": .string("👍")
        ])
        try await conference.sendJSONMessage(payload, to: "p1")
        XCTAssertEqual(engine?.jsonMessages.last?.payload, payload)
        XCTAssertEqual(engine?.jsonMessages.last?.to, "p1")

        do {
            try await conference.sendJSONMessage(.array([.string("not-an-object")]))
            XCTFail("an array payload must be rejected")
        } catch let JitsiError.invalidArgument(detail) {
            XCTAssertTrue(detail.contains("JSON object"))
        }
        await model.leave()
    }

    /// Presence commands, bridge data-channel messages and reactions are three separate lib
    /// paths; routing one through another would still "succeed" but deliver nothing.
    func testCommandsEndpointMessagesAndReactionsReachTheEngine() async throws {
        let model = await joinedModel()
        let conference = try XCTUnwrap(model.conference)

        try await conference.sendCommand("jitsi_participant_probe", values: ["value": .string("1")])
        try await conference.sendCommandOnce("probe-once", values: ["value": .bool(true)])
        try await conference.removeCommand("probe-once")
        try await conference.addCommandListener("probe")
        try await conference.removeCommandListener("probe")
        try await conference.sendEndpointMessage(.object(["kind": .string("ping")]), to: "p1")
        try await conference.sendReaction("👍", messageID: "m1", to: "p1")

        XCTAssertEqual(engine?.commands.count, 2)
        XCTAssertEqual(engine?.commands.first?.name, "jitsi_participant_probe")
        XCTAssertEqual(engine?.commands.first?.values["value"], .string("1"))
        XCTAssertEqual(engine?.commands.first?.once, false)
        XCTAssertEqual(engine?.commands.last?.name, "probe-once")
        XCTAssertEqual(engine?.commands.last?.values["value"], .bool(true))
        XCTAssertEqual(engine?.commands.last?.once, true)
        XCTAssertEqual(engine?.removedCommands, ["probe-once"])
        XCTAssertEqual(engine?.commandListenerAdds, ["probe"])
        XCTAssertEqual(engine?.commandListenerRemovals, ["probe"])
        XCTAssertEqual(engine?.endpointMessages.first?.payload, .object(["kind": .string("ping")]))
        XCTAssertEqual(engine?.endpointMessages.first?.to, "p1")
        XCTAssertEqual(engine?.reactions.first?.reaction, "👍")
        XCTAssertEqual(engine?.reactions.first?.messageID, "m1")
        XCTAssertEqual(engine?.reactions.first?.to, "p1")
        await model.leave()
    }

    func testSignalingRejectsMissingNamesAndNonObjectPayloads() async throws {
        let model = await joinedModel()
        let conference = try XCTUnwrap(model.conference)

        do {
            try await conference.sendCommand("")
            XCTFail("an empty command name must be rejected")
        } catch let JitsiError.invalidArgument(detail) {
            XCTAssertTrue(detail.contains("command name"))
        }
        do {
            try await conference.sendReaction("")
            XCTFail("an empty reaction must be rejected")
        } catch let JitsiError.invalidArgument(detail) {
            XCTAssertTrue(detail.contains("reaction"))
        }
        do {
            try await conference.sendEndpointMessage(.array([]))
            XCTFail("an array endpoint payload must be rejected")
        } catch let JitsiError.invalidArgument(detail) {
            XCTAssertTrue(detail.contains("JSON object"))
        }
        XCTAssertTrue(engine?.commands.isEmpty == true)
        XCTAssertTrue(engine?.reactions.isEmpty == true)
        XCTAssertTrue(engine?.endpointMessages.isEmpty == true)
        await model.leave()
    }

    func testModeratorControlsReachTheEngine() async {
        let model = await joinedModel()
        model.lockRoom(password: "1234")
        model.unlockRoom()
        model.grantModerator("p1")
        model.revokeModerator("local")
        model.setSilent(true)
        model.setSubject("Weekly sync")
        model.setStartMutedPolicy(audio: true, video: false)
        model.endConference()

        await waitUntil(timeout: 5) {
            let engine = self.engine
            return engine?.lockPasswords.count == 1
                && engine?.unlockCount == 1
                && engine?.ownerChanges.count == 2
                && engine?.silentValues.count == 1
                && engine?.subjects.count == 1
                && engine?.startMutedPolicies.count == 1
                && engine?.endCount == 1
        }
        XCTAssertEqual(engine?.lockPasswords, ["1234"])
        XCTAssertEqual(engine?.unlockCount, 1)
        XCTAssertTrue(engine?.ownerChanges.contains { $0.id == "p1" && $0.granted } == true,
                      "ownerChanges: \(String(describing: engine?.ownerChanges))")
        XCTAssertTrue(engine?.ownerChanges.contains { $0.id == "local" && !$0.granted } == true,
                      "resigning passes the local id through: \(String(describing: engine?.ownerChanges))")
        XCTAssertEqual(engine?.silentValues, [true])
        XCTAssertEqual(engine?.subjects, ["Weekly sync"])
        XCTAssertEqual(engine?.startMutedPolicies, [StartMutedPolicy(audio: true, video: false)])
        XCTAssertEqual(engine?.endCount, 1)
        XCTAssertNil(model.message)
        await model.leave()
    }

    /// The lib has no lock getter: `conference.state()` mirrors `LOCK_STATE_CHANGED`, and a
    /// remote lock/unlock must keep both the room and the model truthful.
    func testLockStateAndPolicyComeFromTheServer() async throws {
        let model = await joinedModel()
        engine?.conferenceStateValue = .object([
            "isModerator": .bool(true),
            "isLocked": .bool(true),
            "endConferenceSupported": .bool(true),
            "startMutedPolicy": .object(["audio": .bool(true), "video": .bool(false)])
        ])
        JitsiMeet.shared.events.publish(.conferenceJoined("demo-room"))
        await waitUntil { model.isLocked && model.conference?.canEndConference == true }

        let room = try XCTUnwrap(model.conference)
        XCTAssertTrue(room.isLocked)
        XCTAssertTrue(room.canEndConference)
        XCTAssertEqual(room.startMutedPolicy, StartMutedPolicy(audio: true, video: false))
        XCTAssertEqual(model.startMutedPolicy, StartMutedPolicy(audio: true, video: false))

        JitsiMeet.shared.events.publish(.lockStateChanged(false))
        await waitUntil { !model.isLocked && !room.isLocked }

        JitsiMeet.shared.events.publish(.conferenceLeft(reason: nil))
        await waitUntil { !room.canEndConference && !room.isLocked }
        XCTAssertFalse(room.canEndConference)
        XCTAssertFalse(room.isLocked)
        await model.leave()
    }

    /// Room-visibility events (members-only, visitors, silent/bot flags, dial-in number) are
    /// event-only in the lib, so the conference mirror has to absorb them as they arrive.
    func testVisibilityEventsUpdateConferenceMirror() async throws {
        let model = await joinedModel()
        let room = try XCTUnwrap(model.conference)
        JitsiMeet.shared.events.publish(.participantJoined(
            ParticipantSnapshot(id: "p1", displayName: "Pat")))
        await waitUntil { room.participants["p1"] != nil }

        JitsiMeet.shared.events.publish(.membersOnlyChanged(true))
        JitsiMeet.shared.events.publish(.visitorsSupportedChanged(true))
        JitsiMeet.shared.events.publish(.phoneNumberChanged("+15550100"))
        JitsiMeet.shared.events.publish(.silentStatusChanged("p1", true))
        JitsiMeet.shared.events.publish(.botTypeChanged("p1", "transcription"))
        await waitUntil {
            room.lobbyEnabled && room.visitorsSupported && model.visitorsSupported
                && room.phoneNumber == "+15550100"
                && room.participants["p1"]?.snapshot.isSilent == true
                && room.participants["p1"]?.snapshot.botType == "transcription"
        }
        XCTAssertTrue(room.lobbyEnabled)
        XCTAssertTrue(room.visitorsSupported)
        XCTAssertEqual(room.phoneNumber, "+15550100")
        XCTAssertEqual(room.participants["p1"]?.snapshot.isSilent, true)
        XCTAssertEqual(room.participants["p1"]?.snapshot.botType, "transcription")

        JitsiMeet.shared.events.publish(.conferenceLeft(reason: nil))
        await waitUntil { room.phoneNumber == nil && !room.visitorsSupported }
        XCTAssertNil(room.phoneNumber)
        await model.leave()
    }

    /// The lib getter returns a string, so a string array would be flattened. The mirror is
    /// the contract: what the caller wrote is what the caller reads back.
    func testLocalParticipantPropertiesKeepTheirJSONShape() async throws {        let model = await joinedModel()
        let room = try XCTUnwrap(model.conference)
        engine?.conferenceStateValue = .object([
            "myUserId": .string("me-123"),
            "localParticipantProperties": .object(["status": .string("ready")]),
            "visitorsSupported": .bool(true)
        ])
        JitsiMeet.shared.events.publish(.conferenceJoined("demo-room"))
        await waitUntil {
            room.localParticipantID == "me-123" && room.visitorsSupported && model.visitorsSupported
        }
        XCTAssertEqual(room.localParticipantProperties["status"], .string("ready"))
        XCTAssertEqual(model.localParticipantProperties["status"], .string("ready"))
        XCTAssertTrue(model.visitorsSupported)

        let tags: JSONValue = .array([.string("a"), .string("b")])
        model.setLocalParticipantProperty("tags", value: tags)
        await waitUntil { engine?.localPropertyWrites.count == 1 }
        XCTAssertEqual(engine?.localPropertyWrites.first?.name, "tags")
        XCTAssertEqual(engine?.localPropertyWrites.first?.value, tags)
        await waitUntil { model.localParticipantProperties["tags"] == tags }

        let read = await model.localParticipantProperty("tags")
        XCTAssertEqual(read, tags)
        XCTAssertEqual(engine?.localPropertyReads, ["tags"])

        model.removeLocalParticipantProperty("tags")
        await waitUntil {
            self.engine?.localPropertyRemovals == ["tags"]
                && model.localParticipantProperties["tags"] == nil
        }
        XCTAssertNil(model.message)
        await model.leave()
    }

    /// A local property change carries the local MUC resource, which is not in the
    /// participant map; it must update the mirror instead of inventing a peer.
    func testLocalPropertyEventUpdatesTheMirrorOnly() async throws {
        let model = await joinedModel()
        let room = try XCTUnwrap(model.conference)
        engine?.conferenceStateValue = .object(["myUserId": .string("me-123")])
        JitsiMeet.shared.events.publish(.conferenceJoined("demo-room"))
        await waitUntil { room.localParticipantID == "me-123" }

        JitsiMeet.shared.events.publish(.participantPropertyChanged(
            "me-123", key: "raiseHand", value: .bool(true), previous: nil))
        await waitUntil {
            room.localParticipantProperties["raiseHand"] == .bool(true)
                && model.localParticipantProperties["raiseHand"] == .bool(true)
        }
        XCTAssertNil(room.participants["me-123"])
        XCTAssertEqual(model.localParticipantProperties["raiseHand"], .bool(true))

        JitsiMeet.shared.events.publish(.participantPropertyChanged(
            "me-123", key: "raiseHand", value: .null, previous: .bool(true)))
        await waitUntil { room.localParticipantProperties["raiseHand"] == nil }
        await model.leave()
    }

    /// `PROPERTIES_CHANGED` is jicofo's room state and `PARTICIPANT_PROPERTY_CHANGED` is a
    /// presence delta; they must land on separate models.
    func testConferenceAndParticipantPropertiesSurface() async throws {
        let model = await joinedModel()
        let room = try XCTUnwrap(model.conference)
        JitsiMeet.shared.events.publish(.participantJoined(
            ParticipantSnapshot(id: "p1", displayName: "Pat")))
        JitsiMeet.shared.events.publish(.participantPropertyChanged(
            "p1",
            key: "jitsi_participant_lang",
            value: .array([.string("zh"), .string("en")]),
            previous: nil))
        await waitUntil { room.participants["p1"]?.snapshot.properties["jitsi_participant_lang"] != nil }
        XCTAssertEqual(
            room.participants["p1"]?.snapshot.properties["jitsi_participant_lang"],
            .array([.string("zh"), .string("en")]))

        JitsiMeet.shared.events.publish(.conferencePropertiesChanged(.object([
            "audio-limit-reached": .bool(true),
            "bridge-count": .number(2)
        ])))
        await waitUntil {
            room.conferenceProperties["bridge-count"] == .number(2)
                && model.conferenceProperties["bridge-count"] == .number(2)
        }
        XCTAssertEqual(room.conferenceProperties["audio-limit-reached"], .bool(true))
        XCTAssertEqual(model.conferenceProperties["audio-limit-reached"], .bool(true))

        JitsiMeet.shared.events.publish(.participantPropertyChanged(
            "p1", key: "jitsi_participant_lang", value: .null, previous: nil))
        await waitUntil { room.participants["p1"]?.snapshot.properties["jitsi_participant_lang"] == nil }
        await model.leave()
    }

    func testConnectionPropertiesExposeRegionAndShard() async throws {
        let connection = try JitsiMeet.shared.createConnection(
            JitsiMeetDemo.connection(host: "meet.example.org"))
        JitsiMeet.shared.events.publish(.connectionPropertiesUpdated(.object([
            "region": .string("eu-west"),
            "shard": .string("shard-1")
        ])))
        await waitUntil { connection.properties.count == 2 }
        XCTAssertEqual(connection.deploymentRegion, "eu-west")
        XCTAssertEqual(connection.deploymentShard, "shard-1")
    }

    /// Participant rows expose the lib's detail getters, and speaker stats surface as a
    /// list rather than the lib's id-keyed map.
    func testParticipantDetailsAndSpeakerStatsSurface() async throws {
        let model = await joinedModel()
        let room = try XCTUnwrap(model.conference)
        JitsiMeet.shared.events.publish(.participantJoined(ParticipantSnapshot(
            id: "p1",
            displayName: "Ada",
            role: .moderator,
            // The participant-level mute flags are folded from the tracks, so the snapshots
            // have to carry them for the detail getters to report a live video.
            tracks: [
                TrackSnapshot(id: "p1-audio", mediaType: .audio, isLocal: false, muted: true),
                TrackSnapshot(id: "p1-video", mediaType: .video, isLocal: false, muted: false)
            ],
            jid: "p1@room.test/res",
            connectionJID: "p1@room.test/conn",
            status: "busy",
            botType: "transcription",
            statsID: "stats-1",
            isSilent: true,
            isReplacing: true,
            isReplaced: false,
            isHidden: true,
            isAudioMuted: true,
            isVideoMuted: false
        )))
        await waitUntil { room.participants["p1"] != nil }

        let participant = try XCTUnwrap(room.participants["p1"])
        XCTAssertEqual(participant.jid, "p1@room.test/res")
        XCTAssertEqual(participant.connectionJID, "p1@room.test/conn")
        XCTAssertEqual(participant.status, "busy")
        XCTAssertEqual(participant.botType, "transcription")
        XCTAssertEqual(participant.statsID, "stats-1")
        XCTAssertTrue(participant.isSilent)
        XCTAssertTrue(participant.isReplacing)
        XCTAssertFalse(participant.isReplaced)
        XCTAssertTrue(participant.isHidden)
        XCTAssertTrue(participant.isAudioMuted)
        XCTAssertFalse(participant.isVideoMuted)
        XCTAssertTrue(participant.role == .moderator)

        engine?.speakerStatsValue = [
            SpeakerStats(
                participantID: "p1",
                displayName: "Ada",
                isDominantSpeaker: true,
                totalDominantSpeakerTime: 12.5,
                faceLandmarks: [.init(duration: 3, faceExpression: "happy")]
            ),
            SpeakerStats(participantID: "p2", displayName: "Bob", hasLeft: true)
        ]
        let stats = await model.speakerStats()
        XCTAssertEqual(stats.count, 2)
        XCTAssertEqual(stats.first?.participantID, "p1")
        XCTAssertTrue(stats.first?.isDominantSpeaker == true)
        XCTAssertEqual(stats.first?.totalDominantSpeakerTime, 12.5)
        XCTAssertEqual(stats.first?.faceLandmarks.first, .init(duration: 3, faceExpression: "happy"))
        XCTAssertTrue(stats.last?.hasLeft == true)
        await model.leave()
    }

    func testLobbyModerationReachesTheEngine() async {
        let model = await joinedModel()
        model.approveLobbyUser("guest-1")
        model.denyLobbyUser("guest-2")
        model.sendLobbyMessage(.object(["type": .string("hello")]), to: "guest-1")
        engine?.lobbyUserIDValue = "guest-1"

        await waitUntil(timeout: 5) {
            self.engine?.lobbyApprovals.count == 1
                && self.engine?.lobbyDenials.count == 1
                && self.engine?.lobbyMessages.count == 1
        }
        XCTAssertEqual(engine?.lobbyApprovals, ["guest-1"])
        XCTAssertEqual(engine?.lobbyDenials, ["guest-2"])
        XCTAssertEqual(engine?.lobbyMessages.first?.message, .object(["type": .string("hello")]))
        XCTAssertEqual(engine?.lobbyMessages.first?.to, "guest-1")
        let id = await model.myLobbyUserID()
        XCTAssertEqual(id, "guest-1")
        XCTAssertNil(model.message)
        await model.leave()
    }

    /// Lobby events arrive as deltas; the room keeps one merged row per waiting user.
    func testLobbyUsersMergeUpdatesAndLeave() async {
        let model = await joinedModel()
        JitsiMeet.shared.events.publish(.lobbyUserJoined(
            LobbyUser(id: "guest-2", displayName: "Bob", email: "bob@example.test")))
        await waitUntil { model.lobbyUsers.count == 1 }
        XCTAssertEqual(model.lobbyUsers.first?.displayName, "Bob")

        JitsiMeet.shared.events.publish(.lobbyUserUpdated(
            LobbyUser(id: "guest-2", displayName: "Bob", email: "new@example.test")))
        await waitUntil { model.lobbyUsers.first?.email == "new@example.test" }
        XCTAssertEqual(model.lobbyUsers.first?.displayName, "Bob")

        JitsiMeet.shared.events.publish(.lobbyUserLeft("guest-2"))
        await waitUntil { model.lobbyUsers.isEmpty }
        await model.leave()
    }

    /// meet.jit.si refuses anonymous guests with `membersOnly` until a moderator starts the
    /// room. Upstream jitsi-meet treats it as recoverable and knocks in the lobby instead of
    /// ending the call, and the approval joins the main room on its own.
    func testMembersOnlyFailureKnocksInTheLobby() async {
        let model = await joinedModel(JitsiMeetDemo.conference(
            room: "demo-room", displayName: "Ada", email: "ada@example.test"))
        JitsiMeet.shared.events.publish(.conferenceFailed(
            .remote("conference.connectionError.membersOnly")))

        await waitUntil { self.engine?.joinLobbyCalls.count == 1 }
        XCTAssertTrue(model.isWaitingInLobby)
        XCTAssertFalse(model.isWaitingForHost)
        XCTAssertEqual(engine?.joinLobbyCalls.first?.displayName, "Ada")
        XCTAssertEqual(engine?.joinLobbyCalls.first?.email, "ada@example.test")
        XCTAssertTrue(model.message?.contains("Waiting for a moderator") == true)
        XCTAssertFalse(model.canRetryConnection, "a retry would tear the lobby down")

        JitsiMeet.shared.events.publish(.conferenceJoined("demo-room"))
        await waitUntil { model.isJoined }
        XCTAssertFalse(model.isWaitingInLobby)
        XCTAssertNil(model.message)
        await model.leave()
    }

    /// A `waiting-for-host` lobby admits guests automatically when an authenticated host
    /// starts the meeting, so the UI must not promise that a moderator will approve them.
    func testWaitForHostLobbyExplainsThereIsNoApproval() async {
        let model = await joinedModel(JitsiMeetDemo.conference(
            room: "demo-room", displayName: "Ada", email: "ada@example.test"))
        JitsiMeet.shared.events.publish(.lobbyWaitingForHost(true))
        JitsiMeet.shared.events.publish(.conferenceFailed(
            .remote("conference.connectionError.membersOnly")))

        await waitUntil { self.engine?.joinLobbyCalls.count == 1 }
        XCTAssertTrue(model.isWaitingInLobby)
        XCTAssertTrue(model.isWaitingForHost)
        XCTAssertTrue(model.message?.contains("Waiting for the host") == true)

        JitsiMeet.shared.events.publish(.conferenceJoined("demo-room"))
        await waitUntil { model.isJoined }
        XCTAssertFalse(model.isWaitingInLobby)
        XCTAssertFalse(model.isWaitingForHost)
        XCTAssertNil(model.message)
        await model.leave()
    }

    /// A password-protected room refuses the join with `passwordRequired`. Only the user
    /// knows the password, so the model reports it instead of knocking or retrying.
    func testPasswordRequiredIsSurfacedInsteadOfRetried() async {
        let model = await joinedModel(JitsiMeetDemo.conference(
            room: "demo-room", displayName: "Ada"))
        JitsiMeet.shared.events.publish(.conferenceFailed(
            .remote("conference.passwordRequired")))

        await waitUntil { model.requiresPassword }
        XCTAssertEqual(model.message, "This room requires a password.")
        XCTAssertFalse(model.isWaitingInLobby)
        XCTAssertTrue(engine?.joinLobbyCalls.isEmpty ?? false)
        XCTAssertFalse(model.canRetryConnection, "a blind retry cannot guess the password")

        JitsiMeet.shared.events.publish(.conferenceJoined("demo-room"))
        await waitUntil { model.isJoined }
        XCTAssertFalse(model.requiresPassword)
        await model.leave()
    }

    /// A denial kicks the guest out of the lobby; the waiting overlay must go away and the
    /// error is the host's cue to offer a retry.
    func testLobbyDenialStopsWaiting() async {
        let model = await joinedModel()
        JitsiMeet.shared.events.publish(.conferenceFailed(
            .remote("conference.connectionError.membersOnly")))
        await waitUntil { model.isWaitingInLobby }

        JitsiMeet.shared.events.publish(.conferenceFailed(
            .remote("conference.connectionError.accessDenied")))
        await waitUntil { !model.isWaitingInLobby }
        XCTAssertFalse(model.isWaitingInLobby)
        XCTAssertTrue(model.message?.contains("denied") == true)
        XCTAssertTrue(model.canRetryConnection)
        await model.leave()
    }

    /// Only the members-only refusal has a lobby to knock on; every other failure keeps the
    /// old banner behaviour.
    func testOtherFailuresDoNotKnockInTheLobby() async {
        let model = await joinedModel()
        JitsiMeet.shared.events.publish(.conferenceFailed(
            .remote("conference.connectionError.passwordRequired")))
        await waitUntil { model.message != nil }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(model.isWaitingInLobby)
        XCTAssertEqual(engine?.joinLobbyCalls.count, 0)
        await model.leave()
    }

    func testAVModerationReachesTheEngineAndTracksState() async {
        let model = await joinedModel()
        let supported = await model.isAVModerationSupported()
        XCTAssertTrue(supported)

        model.enableAVModeration(.audio)
        model.disableAVModeration(.desktop)
        model.approveAVModeration("p1", mediaType: .video)
        model.rejectAVModeration("p2", mediaType: .video)
        await waitUntil(timeout: 5) { self.engine?.avModerationCalls.count == 4 }
        // The model fires these as independent tasks, so completion order is not guaranteed.
        let calls = engine?.avModerationCalls ?? []
        XCTAssertEqual(Set(calls.map { $0.action }), ["enable", "disable", "approve", "reject"])
        XCTAssertTrue(calls.contains { $0.action == "enable" && $0.mediaType == .audio })
        XCTAssertTrue(calls.contains { $0.action == "disable" && $0.mediaType == .desktop })
        XCTAssertTrue(calls.contains {
            $0.action == "approve" && $0.mediaType == .video && $0.id == "p1"
        })
        XCTAssertTrue(calls.contains {
            $0.action == "reject" && $0.mediaType == .video && $0.id == "p2"
        })

        JitsiMeet.shared.events.publish(.avModerationChanged(enabled: true, mediaType: .audio, actor: "p1"))
        await waitUntil { model.avModeration[.audio] == true }
        XCTAssertTrue(model.isAVModerationEnabled(.audio))

        JitsiMeet.shared.events.publish(.avModerationParticipantApproved("p1", .video))
        await waitUntil { model.avModeration[.video] == true }

        JitsiMeet.shared.events.publish(.avModerationRejected(.desktop))
        await waitUntil { model.avModeration[.desktop] == false }
        XCTAssertNil(model.message)
        await model.leave()
    }

    /// lib-jitsi-meet builds a room JID as `name@customDomain`, so a full breakout JID has to
    /// be split; passing it as the name would produce `abc@breakout...@muc...`.
    func testBreakoutRoomJIDIsSplitIntoNameAndDomain() throws {
        let base = JitsiMeetDemo.conference(room: "demo-room", displayName: "Demo")
        let target = try base.room(atJID: "abc123@breakout.meet.jitsi")
        XCTAssertEqual(target.name, "abc123")
        XCTAssertEqual(target.configOverwrite["customDomain"], .string("breakout.meet.jitsi"))
        XCTAssertThrowsError(try base.room(atJID: "no-domain"))
    }

    /// lib-jitsi-meet throws "Invalid conference name" for any uppercase letter, while
    /// jitsi-meet normalizes the room from the URL (decode → NFKC → lowercase → encode)
    /// before joining. A name pasted from `https://meet.jit.si/ReligiousHealthcaresKickFree`
    /// must therefore resolve to the same MUC the browser is in.
    func testConferenceNameIsNormalizedLikeTheWebClient() {
        let pasted = JitsiMeetDemo.conference(
            room: "ReligiousHealthcaresKickFree", displayName: "Demo")
        XCTAssertEqual(pasted.name, "religioushealthcareskickfree")

        let encoded = ConferenceOptions(
            name: "Caf%C3%A9%20Room", userInfo: UserInfo(displayName: "Demo"))
        XCTAssertEqual(encoded.name, "caf%C3%A9%20room")

        XCTAssertEqual(
            ConferenceOptions.normalizedRoomName("ＡＢＣ　room"),
            "abc%20room",
            "full-width characters are NFKC-folded before lowercasing")
    }

    func testBreakoutSnapshotAndModerationCallsReachTheEngine() async throws {
        let model = await joinedModel()
        let room = try XCTUnwrap(model.conference)
        let state = BreakoutRoomsState(
            isSupported: true,
            canRename: true,
            rooms: [BreakoutRoom(id: "1", jid: "abc@breakout.meet.jitsi", name: "Design")],
            roomCounter: 1
        )
        JitsiMeet.shared.events.publish(.breakoutRoomsUpdated(state))
        await waitUntil { model.breakoutRooms.count == 1 }
        XCTAssertEqual(room.breakoutRooms, state.rooms)
        XCTAssertEqual(model.breakoutRooms, state.rooms)
        XCTAssertTrue(room.breakoutRoomsSupported)
        XCTAssertTrue(room.canRenameBreakoutRooms)
        XCTAssertFalse(model.isInBreakoutRoom)

        model.createBreakoutRoom("  Ops  ")
        model.renameBreakoutRoom("abc@breakout.meet.jitsi", subject: " Dev ")
        model.removeBreakoutRoom("abc@breakout.meet.jitsi")
        model.sendParticipant("p1", toBreakoutRoom: "abc@breakout.meet.jitsi")
        await waitUntil(timeout: 5) {
            self.engine?.createdBreakoutSubjects.count == 1
                && self.engine?.renamedBreakoutRooms.count == 1
                && self.engine?.removedBreakoutRooms.count == 1
                && self.engine?.breakoutMoves.count == 1
        }
        XCTAssertEqual(engine?.createdBreakoutSubjects, ["Ops"])
        XCTAssertEqual(engine?.renamedBreakoutRooms.first?.subject, "Dev")
        XCTAssertEqual(engine?.removedBreakoutRooms, ["abc@breakout.meet.jitsi"])
        XCTAssertEqual(engine?.breakoutMoves.first?.participantID, "p1")
        XCTAssertEqual(engine?.breakoutMoves.first?.roomJID, "abc@breakout.meet.jitsi")
        XCTAssertNil(model.message)
        await model.leave()
    }

    func testBreakoutRoomsAreClearedWhenTheRoomEnds() async throws {
        let model = await joinedModel()
        let room = try XCTUnwrap(model.conference)
        JitsiMeet.shared.events.publish(.breakoutRoomsUpdated(BreakoutRoomsState(
            isSupported: true,
            isBreakoutRoom: true,
            mainRoomJID: "demo-room@muc.meet.jitsi",
            rooms: [BreakoutRoom(id: "1", jid: "abc@breakout.meet.jitsi", name: "Design")]
        )))
        await waitUntil { room.isInBreakoutRoom && model.isInBreakoutRoom }
        XCTAssertEqual(room.breakoutMainRoomJID, "demo-room@muc.meet.jitsi")

        JitsiMeet.shared.events.publish(.conferenceLeft(reason: nil))
        await waitUntil { !room.isInBreakoutRoom && model.breakoutRooms.isEmpty }
        XCTAssertNil(room.breakoutMainRoomJID)
        await model.leave()
    }

    /// Upstream default: `BREAKOUT_ROOMS_MOVE_TO_ROOM` is followed automatically. The switch
    /// reuses the connection and the tracks, so no reconnect may happen.
    func testAutoFollowsMoveToRoomOnTheSameConnection() async throws {
        let model = await joinedModel()
        JitsiMeet.shared.events.publish(.conferenceJoined("demo-room"))
        await waitUntil { model.isJoined }

        JitsiMeet.shared.events.publish(.breakoutRoomsMoveToRoom(roomJID: "abc123@breakout.meet.jitsi"))
        await waitUntil(timeout: 5) { self.engine?.switches.count == 1 && !model.isSwitchingRoom }
        let target = try XCTUnwrap(engine?.switches.first)
        XCTAssertEqual(target.name, "abc123")
        XCTAssertEqual(target.configOverwrite["customDomain"], .string("breakout.meet.jitsi"))
        XCTAssertEqual(engine?.connectCount, 1, "a breakout switch must not rebuild the connection")
        XCTAssertNil(model.message)
        await model.leave()
    }

    func testReturnToMainRoomUsesTheOriginalOptions() async throws {
        let model = await joinedModel()
        JitsiMeet.shared.events.publish(.conferenceJoined("demo-room"))
        await waitUntil { model.isJoined }
        JitsiMeet.shared.events.publish(.breakoutRoomsMoveToRoom(roomJID: "abc123@breakout.meet.jitsi"))
        await waitUntil(timeout: 5) { self.engine?.switches.count == 1 && !model.isSwitchingRoom }

        model.returnToMainRoom()
        await waitUntil(timeout: 5) { self.engine?.switches.count == 2 && !model.isSwitchingRoom }
        let mainRoom = try XCTUnwrap(engine?.switches.last)
        XCTAssertEqual(mainRoom.name, "demo-room")
        XCTAssertNil(mainRoom.configOverwrite["customDomain"])
        await model.leave()
    }

    /// Receiver hints and the bandwidth estimate both feed the lib's receiver-side picker;
    /// every field is forwarded untouched so partial updates keep the previous value.
    func testReceiverConstraintsAndBandwidthReachTheEngine() async throws {
        let model = await joinedModel()
        let conference = try XCTUnwrap(model.conference)
        let full = ReceiverConstraints(
            lastN: 12, defaultMaxHeight: 360,
            sourceMaxHeights: ["cam": 720], assumedBandwidthBps: 900_000)
        try await conference.setReceiverConstraints(full)
        try await conference.setAssumedBandwidthBps(900_000)
        XCTAssertEqual(engine?.receiverConstraints.last, full)
        XCTAssertEqual(engine?.assumedBandwidthValues, [900_000])

        model.setReceiverConstraints(ReceiverConstraints(lastN: 4))
        await waitUntil { self.engine?.receiverConstraints.count == 2 }
        XCTAssertEqual(engine?.receiverConstraints.last, ReceiverConstraints(lastN: 4))
        await model.leave()
    }

    /// The lib returns a boolean for the desktop share frame rate; a false must reach the
    /// caller instead of being swallowed.
    func testDesktopSharingFrameRateReportsTheLibVerdict() async throws {
        let model = await joinedModel()
        let conference = try XCTUnwrap(model.conference)
        engine?.desktopFrameRateAccepted = true
        let accepted = try await conference.setDesktopSharingFrameRate(30)
        engine?.desktopFrameRateAccepted = false
        let rejected = try await conference.setDesktopSharingFrameRate(5)
        XCTAssertTrue(accepted)
        XCTAssertFalse(rejected)
        XCTAssertEqual(engine?.desktopFrameRates, [30, 5])
        await model.leave()
    }

    /// `replaceTrack` swaps a live sender without renegotiating: the Swift registry must
    /// drop the old id and expose the replacement returned by the lib.
    func testReplaceTrackSwapsTheLocalRegistry() async throws {
        let model = await joinedModel()
        JitsiMeet.shared.events.publish(.localTrackAdded(
            TrackSnapshot(id: "cam", mediaType: .video, isLocal: true, videoType: .camera)))
        await waitUntil { model.conference?.localTracks["cam"] != nil }
        let conference = try XCTUnwrap(model.conference)
        engine?.replaceTrackResult = TrackSnapshot(
            id: "cam2", mediaType: .video, isLocal: true, videoType: .camera)

        let replacement = try await conference.replaceTrack("cam", with: "cam2")
        XCTAssertEqual(replacement?.id, "cam2")
        XCTAssertEqual(engine?.replaceTrackCalls.first?.old, "cam")
        XCTAssertEqual(engine?.replaceTrackCalls.first?.new, "cam2")
        XCTAssertNil(conference.localTracks["cam"])
        XCTAssertEqual(conference.localTracks["cam2"]?.id, "cam2")
        await model.leave()
    }

    func testAudioOutputRouteRoundTrips() async throws {
        let model = await joinedModel()
        let conference = try XCTUnwrap(model.conference)
        let initial = try await conference.audioOutputRoute()
        XCTAssertEqual(initial, .receiver)

        try await conference.setAudioOutputRoute(.speaker)
        XCTAssertEqual(engine?.audioOutputRouteWrites, [.speaker])

        model.setAudioOutputRoute(.receiver)
        await waitUntil { self.engine?.audioOutputRouteWrites == [.speaker, .receiver] }
        let route = await model.audioOutputRoute()
        XCTAssertEqual(route, .receiver)

        // The system can move audio to a headset or Bluetooth at any time; the session
        // mirrors that route and reports it, without pretending the built-in request won.
        var changes: [AudioOutputRoute] = []
        model.onEvent = { event in
            if case .audioOutputRouteChanged(let changed) = event { changes.append(changed) }
        }
        JitsiMeet.shared.events.publish(.audioOutputRouteChanged(.bluetooth))
        await waitUntil { model.currentAudioOutputRoute == .bluetooth }
        XCTAssertEqual(model.currentAudioOutputRoute, .bluetooth)
        JitsiMeet.shared.events.publish(.audioOutputRouteChanged(.headphones))
        await waitUntil { model.currentAudioOutputRoute == .headphones }
        XCTAssertEqual(changes, [.bluetooth, .headphones])
        await model.leave()
    }

    /// The pre-call probe runs before any room exists, so it belongs on the SDK entry point
    /// rather than on a conference.
    func testPreCallTestForwardsServersAndReturnsMetrics() async throws {
        engine?.preCallTestResult = PreCallTestResult(
            mediaConnectivity: true, throughput: 1_200_000,
            fractionalLoss: 0.02, rtt: 42, jitter: 3)
        let servers = [PreCallTestServer(
            urls: ["turn:turn.example.org:3478"], username: "user", credential: "secret")]
        let result = try await JitsiMeet.shared.runPreCallTest(servers)
        XCTAssertTrue(result.mediaConnectivity)
        XCTAssertEqual(result.throughput, 1_200_000)
        XCTAssertEqual(result.rtt, 42)
        XCTAssertEqual(engine?.preCallTestServers.first, servers)
    }

    /// Connection metadata and XEP-0115 caps live on the transport, not the room. The stub
    /// never emits CONNECTION_ESTABLISHED itself, so the test publishes it like the engine.
    func testConnectionMetadataFeaturesAndLogsReachTheEngine() async throws {
        engine?.connectionJIDValue = "user@meet.example.org/abc"
        engine?.connectionTimesValue = .object(["bosh": .number(120), "sasl": .number(8)])
        engine?.connectionLogsValue = .object(["jingle": .array([]), "xmpp": .string("<log/>")])
        let connection = try JitsiMeet.shared.createConnection(
            JitsiMeetDemo.connection(host: "meet.example.org"))
        XCTAssertNil(connection.jid)

        let connecting = Task { try await connection.connect() }
        await waitUntil { connection.status == .connecting }
        JitsiMeet.shared.events.publish(.connectionStatus(.connected, message: nil))
        try await connecting.value
        XCTAssertEqual(connection.jid, "user@meet.example.org/abc")

        let times = try await connection.connectionTimes()
        XCTAssertEqual(times, engine?.connectionTimesValue)

        try await connection.addFeature("urn:example:feature", submit: true)
        try await connection.removeFeature("urn:example:feature")
        XCTAssertEqual(engine?.connectionFeatureCalls.map { $0.added }, [true, false])
        XCTAssertEqual(engine?.connectionFeatureCalls.first?.feature, "urn:example:feature")
        XCTAssertEqual(engine?.connectionFeatureCalls.first?.submit, true)

        do {
            try await connection.addFeature("")
            XCTFail("an empty caps feature must be rejected")
        } catch let JitsiError.invalidArgument(detail) {
            XCTAssertTrue(detail.contains("feature"))
        }

        let logs = try await connection.logs()
        XCTAssertEqual(logs, engine?.connectionLogsValue)
        await connection.disconnect()
    }

    func testConnectionAttachForwardsTheSessionAndRejectsEmptyValues() async throws {
        let connection = try JitsiMeet.shared.createConnection(
            JitsiMeetDemo.connection(host: "meet.example.org"))

        do {
            try await connection.attach(rid: "", sid: "s", jid: "u@example.test/r")
            XCTFail("an empty rid must be rejected")
        } catch let JitsiError.invalidArgument(detail) {
            XCTAssertTrue(detail.contains("rid"))
        }

        let attaching = Task {
            try await connection.attach(rid: "1", sid: "sid-1", jid: "user@example.test/res")
        }
        await waitUntil { self.engine?.attachCalls.isEmpty == false }
        JitsiMeet.shared.events.publish(.connectionStatus(.connected, message: nil))
        try await attaching.value
        XCTAssertEqual(engine?.attachCalls.first?.rid, "1")
        XCTAssertEqual(engine?.attachCalls.first?.sid, "sid-1")
        XCTAssertEqual(engine?.attachCalls.first?.jid, "user@example.test/res")
        await connection.disconnect()
    }

    /// DTMF, SIP dial-in and the role upgrade are all conference-level operations; the
    /// gateway check is a local read, so it must not need a successful dial first.
    func testDTMFSIPAndRoleUpgradeReachTheEngine() async throws {
        let model = await joinedModel()
        let conference = try XCTUnwrap(model.conference)

        try await conference.sendTones("1#", duration: 120, pause: 60)
        XCTAssertEqual(engine?.toneCalls.first?.tones, "1#")
        XCTAssertEqual(engine?.toneCalls.first?.duration, 120)
        XCTAssertEqual(engine?.toneCalls.first?.pause, 60)

        engine?.sipSupported = true
        let supported = try await conference.isSIPCallingSupported()
        XCTAssertTrue(supported)

        try await conference.dial("+15550100")
        try await conference.authenticateAndUpgradeRole(id: "moderator", password: "secret")
        XCTAssertEqual(engine?.dialedNumbers, ["+15550100"])
        XCTAssertEqual(engine?.upgradeRoleCalls.first?.id, "moderator")
        XCTAssertEqual(engine?.upgradeRoleCalls.first?.password, "secret")

        do {
            try await conference.sendTones("")
            XCTFail("empty tones must be rejected")
        } catch let JitsiError.invalidArgument(detail) {
            XCTAssertTrue(detail.contains("tones"))
        }
        do {
            try await conference.dial("")
            XCTFail("an empty number must be rejected")
        } catch let JitsiError.invalidArgument(detail) {
            XCTAssertTrue(detail.contains("number"))
        }
        do {
            try await conference.authenticateAndUpgradeRole(id: "moderator", password: "")
            XCTFail("an empty password must be rejected")
        } catch let JitsiError.invalidArgument(detail) {
            XCTAssertTrue(detail.contains("password"))
        }
        await model.leave()
    }

    // MARK: - Remote canvas, media changes and moderation

    private func makeRemote(
        _ id: ParticipantID,
        name: String,
        audioMuted: Bool = false,
        videoMuted: Bool = false
    ) -> MeetingEvent {
        .participantJoined(ParticipantSnapshot(
            id: id,
            displayName: name,
            tracks: [
                TrackSnapshot(id: "\(id)-audio", mediaType: .audio, isLocal: false, muted: audioMuted),
                TrackSnapshot(id: "\(id)-video", mediaType: .video, isLocal: false, muted: videoMuted)
            ]
        ))
    }

    func testRemoteCanvasIsDeliveredOnceAndLeavesOnDeparture() async {
        let model = await joinedModel()
        var joined: [ParticipantCanvas] = []
        var left: [ParticipantID] = []
        model.onRemoteCanvasJoined = { joined.append($0) }
        model.onRemoteCanvasLeft = { left.append($0) }

        JitsiMeet.shared.events.publish(makeRemote("p1", name: "Ada"))
        await waitUntil { joined.count == 1 }
        XCTAssertEqual(joined.first?.id, "p1")
        XCTAssertEqual(joined.first?.displayName, "Ada")
        XCTAssertEqual(model.canvas(for: "p1")?.id, "p1", "a late subscriber can look the canvas up")
        XCTAssertNil(model.canvas(for: "local"), "the local participant never appears in the remote list")

        // A re-announced participant must not produce a second canvas.
        JitsiMeet.shared.events.publish(.participantDisplayNameChanged("p1", "Ada L."))
        await waitUntil { model.tiles.first { $0.id == "p1" }?.displayName == "Ada L." }
        XCTAssertEqual(joined.count, 1)

        JitsiMeet.shared.events.publish(.participantLeft(ParticipantSnapshot(id: "p1", displayName: "Ada L.")))
        await waitUntil { left == ["p1"] }
        XCTAssertNil(model.canvas(for: "p1"))
    }

    func testRemoteMediaChangesAreReportedAndCoalescedIntoAHostMuteBatch() async {
        let model = await joinedModel()
        var changes: [MeetingSession.RemoteMediaChange] = []
        var batches: [MeetingSession.HostMuteAll] = []
        model.onRemoteMediaChanged = { changes.append($0) }
        model.onHostMuteAll = { batches.append($0) }

        JitsiMeet.shared.events.publish(makeRemote("p1", name: "Ada"))
        JitsiMeet.shared.events.publish(makeRemote("p2", name: "Grace"))
        await waitUntil { model.tiles.count == 3 }
        XCTAssertTrue(changes.isEmpty, "the initial state comes with the canvas, not as a change")

        JitsiMeet.shared.events.publish(.participantMuted("p1", .audio, true))
        JitsiMeet.shared.events.publish(.participantMuted("p2", .audio, true))
        await waitUntil { changes.count == 2 }
        XCTAssertTrue(changes.allSatisfy { $0.mediaType == .audio && $0.isMuted })
        XCTAssertEqual(Set(changes.map(\.participantID)), ["p1", "p2"])

        await waitUntil(timeout: 2) { batches.count == 1 }
        XCTAssertEqual(batches.first?.mediaType, .audio)
        XCTAssertEqual(batches.first?.participantIDs, ["p1", "p2"])

        JitsiMeet.shared.events.publish(.participantMuted("p1", .video, true))
        await waitUntil { changes.count == 3 }
        XCTAssertEqual(changes.last?.mediaType, .video)
        XCTAssertEqual(changes.last?.isMuted, true)
    }

    func testTracksArrivingAfterPresenceClearTheInitialMutedState() async {
        let model = await joinedModel()
        JitsiMeet.shared.events.publish(.participantJoined(
            ParticipantSnapshot(id: "p1", displayName: "Ada")
        ))
        await waitUntil { model.tiles.contains { $0.id == "p1" } }
        XCTAssertEqual(model.tiles.first { $0.id == "p1" }?.audioMuted, true,
                       "no track yet means muted, matching lib-jitsi-meet's fold")
        XCTAssertEqual(model.tiles.first { $0.id == "p1" }?.videoMuted, true)

        JitsiMeet.shared.events.publish(.remoteTrackAdded(
            TrackSnapshot(id: "p1-audio", mediaType: .audio, isLocal: false), "p1"
        ))
        JitsiMeet.shared.events.publish(.remoteTrackAdded(
            TrackSnapshot(id: "p1-video", mediaType: .video, isLocal: false), "p1"
        ))
        await waitUntil {
            model.tiles.first { $0.id == "p1" }?.audioMuted == false
                && model.tiles.first { $0.id == "p1" }?.videoMuted == false
        }
    }

    func testAVModerationChangeUsesTheDedicatedCallback() async {
        let model = await joinedModel()
        var changes: [MeetingSession.AVModerationChange] = []
        var selfChanges: [(AVModerationMediaType, Bool)] = []
        model.onAVModerationChanged = { changes.append($0) }
        model.onAVModerationSelfChanged = { selfChanges.append(($0, $1)) }

        JitsiMeet.shared.events.publish(.avModerationChanged(enabled: true, mediaType: .audio, actor: "mod"))
        await waitUntil { changes.count == 1 }
        XCTAssertEqual(changes.first?.mediaType, .audio)
        XCTAssertEqual(changes.first?.isEnabled, true)
        XCTAssertEqual(changes.first?.actorID, "mod")

        JitsiMeet.shared.events.publish(.avModerationApproved(.audio))
        await waitUntil { selfChanges.count == 1 }
        XCTAssertEqual(selfChanges.first?.0, .audio)
        XCTAssertEqual(selfChanges.first?.1, true)
    }

    // MARK: - Meeting timing

    private func joiningModel(meetingTimeLimit: TimeInterval? = nil) async -> MeetingSession {
        let model = MeetingSession()
        try? await model.start(MeetingRequest(
            connection: JitsiMeetDemo.connection(host: "meet.example.org"),
            conference: JitsiMeetDemo.conference(room: "demo-room", displayName: "Demo"),
            capture: [],
            meetingTimeLimit: meetingTimeLimit
        ))
        return model
    }

    func testMeetingTimingFiresOnceWithServerAnchorAndEnforcedLimit() async {
        let model = await joiningModel()
        var callbacks: [MeetingTiming] = []
        model.onMeetingTiming = { callbacks.append($0) }

        JitsiMeet.shared.events.publish(.conferenceJoined("demo-room"))
        let created = Date().addingTimeInterval(-300)
        JitsiMeet.shared.events.publish(.conferenceCreatedTimestamp(
            String(Int(created.timeIntervalSince1970 * 1000))
        ))
        JitsiMeet.shared.events.publish(.nonParticipantMessage(
            from: "",
            text: #"{"type":"time_restricted","durationSeconds":7200,"elapsedSeconds":600}"#
        ))

        await waitUntil { callbacks.count == 1 }
        let timing = callbacks.first
        XCTAssertEqual(timing?.startSource, .serverCreated)
        XCTAssertEqual(timing?.limitSource, .serverEnforced)
        XCTAssertEqual(timing?.timeLimit, 7200)
        XCTAssertEqual(timing?.elapsed(at: Date()) ?? 0, 300, accuracy: 2)

        XCTAssertEqual(model.meetingTiming?.startSource, .serverCreated)
        XCTAssertEqual(model.elapsedSeconds(at: Date()) ?? 0, 300, accuracy: 2)
        XCTAssertEqual(model.remainingSeconds(at: Date()) ?? 0, 6600, accuracy: 3)

        // More source traffic must not fire a second callback.
        JitsiMeet.shared.events.publish(.conferenceCreatedTimestamp(
            String(Int(created.timeIntervalSince1970 * 1000))
        ))
        await Task.yield()
        XCTAssertEqual(callbacks.count, 1)
    }

    func testMeetingTimingFallsBackToTheLocalJoinAfterTheGraceWindow() async {
        let model = await joiningModel(meetingTimeLimit: 3600)
        var callbacks: [MeetingTiming] = []
        model.onMeetingTiming = { callbacks.append($0) }

        JitsiMeet.shared.events.publish(.conferenceJoined("demo-room"))
        await waitUntil(timeout: 3.5) { callbacks.count == 1 }
        XCTAssertEqual(callbacks.first?.startSource, .localJoin)
        XCTAssertEqual(callbacks.first?.limitSource, .hostConfigured)
        XCTAssertEqual(callbacks.first?.timeLimit, 3600)
    }

    func testTimeRestrictedFromAParticipantIsIgnored() async {
        let model = await joiningModel()
        JitsiMeet.shared.events.publish(.conferenceJoined("demo-room"))
        JitsiMeet.shared.events.publish(.nonParticipantMessage(
            from: "p1",
            text: #"{"type":"time_restricted","durationSeconds":60,"elapsedSeconds":0}"#
        ))
        await Task.yield()
        XCTAssertNil(model.meetingTiming?.timeLimit,
                     "only the room itself may set the enforced limit")
    }
}
