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
        // `MeetingModel.start` spawns a receive-policy task that can still hold the engine
        // past the end of the test method; wait for it to release before asserting.
        for _ in 0..<50 where JitsiMeet.shared.engine != nil {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertNil(JitsiMeet.shared.engine)
    }

    private func joinedModel(_ conference: ConferenceOptions? = nil) async -> MeetingModel {
        let model = MeetingModel()
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
        await waitUntil(timeout: 4) { self.engine?.connectCount == connectsBefore + 1 }
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

    func testMeetingModelForwardsVideoConstraints() async {
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

    /// The lib getter returns a string, so a string array would be flattened. The mirror is
    /// the contract: what the caller wrote is what the caller reads back.
    func testLocalParticipantPropertiesKeepTheirJSONShape() async throws {
        let model = await joinedModel()
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
}
