import CoreVideo
import JitsiCore

/// Engine stub for tests that exercise the Swift side of the bridge. Frames are synthetic:
/// they prove plumbing, not media.
final class StubEngine: MeetingEngine {
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
    func prepareConference(_: ConferenceOptions) async throws {}
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
