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

private final class StubEngine: MeetingEngine {
    let events = AsyncStream<MeetingEvent> { $0.finish() }
    private(set) var requestedTrackID: TrackID?
    private let pixelBuffer: CVPixelBuffer = {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 64, 48, kCVPixelFormatType_32BGRA, nil, &buffer)
        return buffer!
    }()

    func frameStream(for trackID: TrackID) -> AsyncStream<VideoPixelFrame> {
        requestedTrackID = trackID
        let buffer = pixelBuffer
        return AsyncStream { continuation in
            continuation.yield(VideoPixelFrame(pixelBuffer: buffer, timestampUs: 1234))
            continuation.finish()
        }
    }

    func install() async throws {}
    func dispose() async {}
    func connect(_: ConnectionOptions) async throws {}
    func disconnect() async {}
    func joinConference(_: ConferenceOptions) async throws {}
    func leaveConference() async {}
    func openCapture(_: [MediaType], deviceIDs _: [String: String]) async throws -> [TrackSnapshot] { [] }
    func closeCapture(_: [TrackID]) async throws {}
    func attachTracks(_: [TrackID]) async throws {}
    func detachTracks(_: [TrackID]) async throws {}
    func setMuted(_: Bool, mediaType: MediaType) async throws {}
    func sendMessage(_: String, to _: ParticipantID?) async throws {}
    func setDisplayName(_: String) async throws {}
    func raiseHand(_: Bool) async throws {}
    func kick(_: ParticipantID) async throws {}
    func muteRemote(_: ParticipantID, mediaType: MediaType, mute: Bool) async throws {}
    func startRecording(_: RecordingOptions) async throws {}
    func stopRecording() async throws {}
    func enableE2EE(key _: String, password _: String?) async throws {}
    func disableE2EE() async throws {}
}
