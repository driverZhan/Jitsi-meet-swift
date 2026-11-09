import JitsiCore
import JitsiMeetExample
import JitsiUI
import XCTest

/// The demo's custom state machine reduces the hub stream without an engine, so the
/// reduction rules are testable on their own.
@MainActor
final class LevelStoreTests: XCTestCase {
    private func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<300 {
            if predicate() { return }
            await Task.yield()
        }
    }

    func testAudioLevelsDriveTheSpeakingRing() async {
        let store = LevelStore()
        store.observe()
        JitsiMeet.shared.events.publish(.audioLevels(["ada": 0.4, "grace": 40]))
        await waitUntil { store.levels.count == 2 }

        XCTAssertEqual(store.level(for: "ada"), 0.4, accuracy: 0.001)
        XCTAssertEqual(store.level(for: "grace"), 0.4, accuracy: 0.001, "0-100 input is treated as the display scale")
        XCTAssertTrue(store.isSpeaking("ada"))
        XCTAssertFalse(store.isSpeaking("nobody"))
        store.stopObserving()
    }

    func testParticipantLeftClearsItsSignals() async {
        let store = LevelStore()
        store.observe()
        JitsiMeet.shared.events.publish(.audioLevels(["ada": 0.6]))
        JitsiMeet.shared.events.publish(.participantMuted("ada", .audio, true))
        JitsiMeet.shared.events.publish(.dominantSpeakerChanged("ada"))
        await waitUntil { store.dominantSpeaker == "ada" }
        XCTAssertTrue(store.isMuted("ada", .audio))

        JitsiMeet.shared.events.publish(.participantLeft(ParticipantSnapshot(id: "ada", displayName: "Ada")))
        await waitUntil { store.levels.isEmpty && store.dominantSpeaker == nil }
        XCTAssertFalse(store.isMuted("ada", .audio))
        store.stopObserving()
    }

    func testUnmodelledBreakoutPayloadReachesTheStore() async {
        let store = LevelStore()
        store.observe()
        JitsiMeet.shared.events.publish(.raw(
            name: "breakoutRoomsUpdated",
            JSONValue.object([
                "rooms": .array([
                    JSONValue.object(["id": .string("breakout-1")]),
                    JSONValue.object(["id": .string("breakout-2")])
                ])
            ])
        ))
        await waitUntil { store.lastBreakoutRooms != nil }

        XCTAssertEqual(store.lastBreakoutRooms?["rooms"]?.arrayValue.count, 2)
        XCTAssertEqual(store.lastBreakoutRooms?["rooms"]?.arrayValue.first?["id"]?.stringValue, "breakout-1")
        XCTAssertTrue(store.log.contains("raw: breakoutRoomsUpdated \(store.lastBreakoutRooms!)"))
        store.stopObserving()
    }

    func testConsoleKeepsTheRecentWindow() async {
        let store = LevelStore()
        store.observe()
        for index in 0..<100 {
            JitsiMeet.shared.events.publish(.dominantSpeakerChanged(index.isMultiple(of: 2) ? "ada" : nil))
        }
        await waitUntil { store.log.count == 80 }

        XCTAssertEqual(store.log.count, 80)
        XCTAssertEqual(store.log.last, "dominantSpeakerChanged")
        store.stopObserving()
    }

    func testStartWithoutAnEngineLandsOnTheBannerChannel() async {
        let model = MeetingModel()
        await model.start(
            JitsiMeetDemo.connection(host: "meet.example.org"),
            conference: JitsiMeetDemo.conference(room: "demo-room", displayName: "Demo")
        )

        XCTAssertEqual(model.message, JitsiError.engineNotInstalled.errorDescription)
        XCTAssertFalse(model.isJoined)
        XCTAssertTrue(model.tiles.isEmpty)
    }

    func testDemoDefaultsTargetTheBOSHDeployment() {
        let options = JitsiMeetDemo.connection()

        XCTAssertEqual(options.serviceUrl, "https://tmeeting.maesgroup.com:8443/http-bind")
        XCTAssertEqual(options.hosts.domain, "meet.jitsi")
        XCTAssertEqual(options.hosts.muc, "muc.meet.jitsi")
    }
}
