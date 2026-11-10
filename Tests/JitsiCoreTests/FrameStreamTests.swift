import CoreVideo
import JitsiCore
import JitsiUI
import XCTest

/// The rendering half of the custom-UI contract: a surface asks `MeetingModel` for frames and
/// the model forwards to whichever engine is installed. A stub engine is enough to prove the
/// plumbing, because frames never travel through signaling.
@MainActor
final class FrameStreamTests: XCTestCase {
    func testFramesComeFromTheInstalledEngine() async throws {
        var engine: StubEngine? = StubEngine()
        JitsiMeet.shared.attach(engine!)
        let model = MeetingModel()

        let stream = model.frames(for: "track-1")
        XCTAssertEqual(engine?.requestedTrackID, "track-1", "the store asks the engine instead of a backend of its own")

        var received: [VideoPixelFrame] = []
        for await frame in stream {
            received.append(frame)
        }
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(CVPixelBufferGetWidth(received[0].pixelBuffer), 64)
        XCTAssertEqual(received[0].timestampUs, 1234)

        engine = nil
        XCTAssertNil(JitsiMeet.shared.engine, "the hub holds the engine weakly, so the stub cannot leak into other tests")
    }

    func testFramesFinishImmediatelyWithoutAnEngine() async {
        let model = MeetingModel()
        var count = 0
        for await _ in model.frames(for: "track-1") {
            count += 1
        }
        XCTAssertEqual(count, 0, "a surface must not wait forever when nothing is installed")
    }
}
