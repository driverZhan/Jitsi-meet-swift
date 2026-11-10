import JitsiCore
import XCTest

@testable import JitsiJSRuntime

/// The JS `MediaStreamTrack` shim passes W3C-style constraints (`{ ideal: … }`), while the
/// Swift facade passes plain numbers. Both must land on the same native request.
final class MediaConstraintsTests: XCTestCase {
    func testParsesPlainAndNestedConstraintValues() {
        let constraints = MediaModule.videoConstraints(.object([
            "width": .number(640),
            "height": .object(["ideal": .number(480)]),
            "frameRate": .object(["exact": .number(15)])
        ]))
        XCTAssertEqual(constraints, VideoConstraints(width: 640, height: 480, frameRate: 15))
    }

    func testMissingConstraintsStayNil() {
        let constraints = MediaModule.videoConstraints(.object([
            "facingMode": .string("user")
        ]))
        XCTAssertEqual(constraints, VideoConstraints())
    }

    func testCapabilitiesJSONCarriesTheFormatsAndActiveFormat() {
        let capabilities = VideoTrackCapabilities(
            formats: [
                .init(width: 1920, height: 1080, minFrameRate: 1, maxFrameRate: 30),
                .init(width: 640, height: 480, minFrameRate: 1, maxFrameRate: 60)
            ],
            activeWidth: 640,
            activeHeight: 480,
            activeFrameRate: 15,
            deviceID: "cam-1")

        let json = MediaModule.capabilitiesJSON(capabilities)
        XCTAssertEqual(json["deviceId"]?.stringValue, "cam-1")
        XCTAssertEqual(json["activeWidth"]?.intValue, 640)
        XCTAssertEqual(json["activeHeight"]?.intValue, 480)
        XCTAssertEqual(json["activeFrameRate"]?.doubleValue, 15)
        XCTAssertEqual(json["formats"]?.arrayValue.count, 2)
        XCTAssertEqual(json["formats"]?.arrayValue.first?["height"]?.intValue, 1080)
        XCTAssertEqual(json["formats"]?.arrayValue.last?["maxFrameRate"]?.doubleValue, 60)
    }
}
