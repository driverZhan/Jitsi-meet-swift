import JitsiCall
import JitsiCore
@testable import JitsiJSRuntime
import JitsiMedia
import XCTest

@MainActor
final class EngineWiringTests: XCTestCase {
    /// The skeleton must fail loudly rather than pretend when libwebrtc is not linked.
    func testInstallFailsWithoutMediaBackend() async {
        let engine = JSMeetingEngine(
            backend: UnavailableMediaBackend(capabilities: .default),
            hostName: "meet.example.org"
        )
        do {
            try await engine.install()
            XCTFail("expected the placeholder backend to refuse to prepare")
        } catch let error as JitsiError {
            XCTAssertEqual(error, .mediaBackendNotLinked)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testConferenceRequiresEngine() async {
        // `JitsiMeet.shared.engine` is unset in a fresh test process; the façade has to say so
        // instead of crashing inside the runtime layer.
        let room = JitsiConference(options: ConferenceOptions(
            name: "standup",
            userInfo: UserInfo(displayName: "Ada")))
        do {
            _ = try await room.capture([.audio])
            XCTFail("expected engineNotInstalled")
        } catch let error as JitsiError {
            XCTAssertEqual(error, .engineNotInstalled)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        await room.leave()
    }

    func testUserInfoRejectsPresenceNamesStropheCannotEncode() async {
        let engine = JSMeetingEngine(
            backend: UnavailableMediaBackend(capabilities: .default),
            hostName: "meet.example.org"
        )
        let options = ConferenceOptions(
            name: "standup",
            userInfo: UserInfo(displayName: "Ada", extras: ["bad key": "x"])
        )
        do {
            try await engine.joinConference(options)
            XCTFail("expected invalidArgument")
        } catch let error as JitsiError {
            XCTAssertEqual(error, .invalidArgument(
                "UserInfo.extras key 'bad key' is not a usable presence element name"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testUserInfoWirePayloadMatchesTheFacadeKeys() {
        let full = JSMeetingEngine.userInfoJSON(UserInfo(
            displayName: "Ada",
            email: "ada@example.test",
            avatarURL: "https://example.test/a.png",
            extras: ["department": "研发"]
        ))
        XCTAssertEqual(full, .object([
            "displayName": .string("Ada"),
            "email": .string("ada@example.test"),
            "avatarURL": .string("https://example.test/a.png"),
            "extras": .object(["department": .string("研发")])
        ]))
        // Optional identity must be omitted, not sent as null/empty: the facade treats an
        // empty value as absent and a null would fail its truthiness check the same way, but
        // keeping the payload minimal is what the presence contract expects.
        let minimal = JSMeetingEngine.userInfoJSON(UserInfo(displayName: "Ada"))
        XCTAssertEqual(minimal, .object(["displayName": .string("Ada")]))
    }
}

@MainActor
final class RegionPolicyTests: XCTestCase {
    func testMainlandNeverOffersSystemCallUI() {
        XCTAssertFalse(RegionPolicy.allowsPushKit(for: .chinaMainland))
        XCTAssertTrue(
            RegionPolicy.describe(for: .chinaMainland).contains("CallKit excluded"),
            "the mainland description must state that CallKit is out of the binary"
        )
    }

    func testMainlandPresenterIsTheNotificationSurface() {
        let presenter = RegionPolicy.presenter(for: .chinaMainland)
        XCTAssertFalse(presenter.strategyName.contains("CallKit"))
        XCTAssertTrue(presenter is SystemInterruptionPresenter)
    }

    func testInternationalFollowsTheCompileFlag() {
        // Without the flag the international build degrades to the same notification surface,
        // so an app can ship one binary and flip presentation at build time only.
        #if JITSI_ENABLE_CALLKIT
        XCTAssertTrue(RegionPolicy.presenter(for: .international).strategyName.contains("CallKit"))
        XCTAssertTrue(RegionPolicy.allowsPushKit(for: .international))
        #else
        XCTAssertFalse(RegionPolicy.allowsPushKit(for: .international))
        #endif
    }
}

final class CallInviteDecoderTests: XCTestCase {
    func testDecodeNestedPayload() {
        let payload: [AnyHashable: Any] = [
            "jitsi": [
                "conference": "team-standup",
                "callerName": "Ada",
                "callerJid": "ada@example.com"
            ]
        ]
        let call = CallInviteDecoder.decode(payload)
        XCTAssertEqual(call?.conference, "team-standup")
        XCTAssertEqual(call?.callerName, "Ada")
        XCTAssertEqual(call?.callerJID, "ada@example.com")
    }

    func testDecodeFlatPayload() {
        let call = CallInviteDecoder.decode(["conference": "room", "callerName": "Grace"])
        XCTAssertEqual(call?.conference, "room")
        XCTAssertEqual(call?.callerName, "Grace")
    }

    func testRejectsPayloadWithoutRoom() {
        XCTAssertNil(CallInviteDecoder.decode(["callerName": "Ada"]))
        XCTAssertNil(CallInviteDecoder.decode(["jitsi": ["callerName": "Ada"]]))
    }

    func testEncodeDecodeRoundTrip() {
        let original = IncomingCall(conference: "room", callerName: "Ada", callerJID: "ada@example.com")
        let decoded = CallInviteDecoder.decode(CallInviteDecoder.encode(original))
        XCTAssertEqual(decoded?.conference, original.conference)
        XCTAssertEqual(decoded?.callerJID, original.callerJID)
    }
}
