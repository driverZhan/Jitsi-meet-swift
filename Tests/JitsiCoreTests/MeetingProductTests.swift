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
}
