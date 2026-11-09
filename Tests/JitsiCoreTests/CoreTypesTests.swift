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
