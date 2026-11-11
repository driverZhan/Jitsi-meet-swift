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

    func testBreakoutRoomsReachTheStore() async {
        let store = LevelStore()
        store.observe()
        JitsiMeet.shared.events.publish(.breakoutRoomsUpdated(BreakoutRoomsState(
            isSupported: true,
            canRename: true,
            rooms: [
                BreakoutRoom(id: "1", jid: "a@breakout.meet.jitsi", name: "Room A"),
                BreakoutRoom(id: "2", jid: "b@breakout.meet.jitsi", name: "Room B")
            ],
            roomCounter: 2
        )))
        await waitUntil { store.lastBreakoutRooms != nil }

        XCTAssertEqual(store.lastBreakoutRooms?.rooms.count, 2)
        XCTAssertEqual(store.lastBreakoutRooms?.rooms.first?.id, "1")
        XCTAssertEqual(store.lastBreakoutRooms?.roomCounter, 2)
        XCTAssertTrue(store.log.contains { $0.contains("breakoutRoomsUpdated") })
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

    func testDemoDefaultsMatchTheSelfHostedDeployment() {
        let options = JitsiMeetDemo.connection()

        XCTAssertEqual(options.serviceUrl, "wss://tmeeting.maesgroup.com:8443/xmpp-websocket")
        XCTAssertEqual(options.hosts.domain, "meet.jitsi")
        XCTAssertEqual(options.hosts.muc, "muc.meet.jitsi")
        XCTAssertNil(options.hosts.anonymousdomain)
    }

    func testPublicMeetJitSiSettingsStayReachableByHost() {
        let options = JitsiMeetDemo.connection(host: "https://meet.jit.si")

        XCTAssertEqual(options.serviceUrl, "wss://meet.jit.si/xmpp-websocket")
        XCTAssertEqual(options.hosts.domain, "meet.jit.si")
        XCTAssertEqual(options.hosts.muc, "conference.meet.jit.si")
        XCTAssertEqual(options.hosts.anonymousdomain, "guest.meet.jit.si")
        // Only the exact meet.jit.si host inherits the guest domain; lookalikes must not.
        XCTAssertNil(JitsiMeetDemo.connection(host: "meet.example.org").hosts.anonymousdomain)
        XCTAssertNil(JitsiMeetDemo.connection(host: "https://meet.jit.si.example.org").hosts.anonymousdomain)
    }
}
