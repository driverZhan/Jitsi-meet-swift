import JitsiCore
import XCTest

final class JSONValueTests: XCTestCase {
    func testRoundTripThroughData() throws {
        let value: JSONValue = .object([
            "joined": .bool(true),
            "level": .number(7),
            "name": .string("standup"),
            "tags": .array([.string("a"), .null]),
            "host": .object(["domain": .string("meet.example.org")])
        ])
        let decoded = try JSONValue(from: value.encoded)
        XCTAssertEqual(decoded, value)
    }

    func testAccessorsIgnoreMismatchedShapes() {
        let value: JSONValue = .object([
            "status": .string("connected"),
            "level": .number(3.9),
            "on": .bool(false),
            "list": .array([.number(1)]),
            "nothing": .null
        ])
        XCTAssertEqual(value["status"]?.stringValue, "connected")
        XCTAssertEqual(value["level"]?.intValue, 3)
        XCTAssertEqual(value["on"]?.boolValue, false)
        XCTAssertEqual(value["list"]?.arrayValue.count, 1)
        XCTAssertFalse(value["nothing"]?.isPresent ?? true)
        XCTAssertNil(value["missing"]?.stringValue)
        XCTAssertNil(JSONValue.string("x")["any"])
        XCTAssertEqual(JSONValue.string("x").arrayValue.count, 0)
    }

    func testUnsupportedLeafThrows() {
        // A JSON body cannot contain a top-level fragment that is not a value; the decoder
        // only accepts Foundation objects produced by JSONSerialization.
        XCTAssertThrowsError(try JSONValue(from: Data("<xml/>".utf8)))
    }
}

final class ConnectionOptionsTests: XCTestCase {
    func testP2PDefaultsToNoPublicSTUN() {
        // lib-jitsi-meet's own default is stun:meet-jit-si-turnrelay.jitsi.net:443, which this
        // SDK must never use: unreachable in mainland China and a third-party address leak.
        let options = ConnectionOptions(
            serviceUrl: "wss://meet.example.test/xmpp-websocket",
            hosts: .init(domain: "meet.example.test", muc: "muc.meet.example.test")
        )
        XCTAssertTrue(options.p2p.stunServers.isEmpty)
        XCTAssertNil(options.p2p.iceTransportPolicy)
    }

    func testP2PConfigurationCarriesRelayPolicy() {
        let p2p = ConnectionOptions.P2PConfiguration(
            stunServers: ["turn:turn.example.test:3478"],
            iceTransportPolicy: .relay
        )
        XCTAssertEqual(p2p.stunServers, ["turn:turn.example.test:3478"])
        XCTAssertEqual(p2p.iceTransportPolicy, .relay)
    }
}

final class JitsiErrorTests: XCTestCase {
    func testRetryableSet() {
        XCTAssertTrue(JitsiError.notConnected.isRetryable)
        XCTAssertTrue(JitsiError.timeout("ice").isRetryable)
        XCTAssertFalse(JitsiError.mediaBackendNotLinked.isRetryable)
        XCTAssertFalse(JitsiError.captureDenied(.audio).isRetryable)
    }

    func testMessagesAreHumanReadable() {
        XCTAssertTrue(JitsiError.mediaBackendNotLinked.localizedDescription.contains("WebRTC"))
        XCTAssertTrue(
            JitsiError.unsupported("raiseHand").localizedDescription.contains("raiseHand")
        )
    }
}
