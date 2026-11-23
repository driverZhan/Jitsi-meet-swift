import AVFoundation
import CoreGraphics
import CoreVideo
import Darwin
import JitsiCore
@testable import JitsiMedia
import XCTest

@MainActor
final class LocalRecordingTests: XCTestCase {
    func testConfigurationDefaultsAndAudioSlot() {
        let url = URL(fileURLWithPath: "/tmp/recording.mp4")
        let config = LocalRecordingConfiguration(outputURL: url)

        XCTAssertEqual(config.outputURL, url)
        XCTAssertEqual(config.canvasSize, CGSize(width: 1280, height: 720))
        XCTAssertEqual(config.frameRate, 30)
        XCTAssertEqual(config.videoBitrate, 2_000_000)
        XCTAssertEqual(config.codec, .h264)
        XCTAssertNil(config.audio, "video-only phase leaves the audio slot empty")
    }

    func testNormalizedFrameKeepsProductCoordinates() {
        let tile = RecordingTile(trackID: "remote-1", frame: CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.25))

        XCTAssertEqual(tile.frame.origin.x, 0.25)
        XCTAssertEqual(tile.frame.origin.y, 0.5, "product layout is top-left origin, stored verbatim")
        XCTAssertEqual(tile.zOrder, 0)
        XCTAssertEqual(tile.rotation, .none)
        XCTAssertEqual(tile.contentMode, .fit)
    }

    /// `place` converts the product's top-left normalized rect into Core Image's bottom-left
    /// pixel rect; this is the core of the recorder's compositing step.
    func testPlaceMapsTopLeftNormalizedFrameToCoreImageCoordinates() {
        let source = CIImage(color: CIColor.red).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100))
        let canvas = CGSize(width: 1280, height: 720)
        let tile = CGRect(x: 0, y: 0, width: 0.5, height: 0.5)

        let result = LocalVideoRecorder.place(source, rotation: .none, in: tile, canvas: canvas, mode: .fit)

        // Target box is the top-left 640x360 in UI == bottom-left 640x360 in Core Image.
        // A square source fitted into 640x360 becomes 360x360, centered horizontally.
        XCTAssertEqual(result.extent.origin.x, 140, accuracy: 0.001)
        XCTAssertEqual(result.extent.origin.y, 360, accuracy: 0.001, "top half in UI == bottom half in Core Image")
        XCTAssertEqual(result.extent.width, 360, accuracy: 0.001)
        XCTAssertEqual(result.extent.height, 360, accuracy: 0.001)
    }

    func testPlaceFitAndFillDifferOnAspectRatio() {
        let source = CIImage(color: CIColor.blue).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 50))
        let canvas = CGSize(width: 400, height: 400)
        let tile = CGRect(x: 0, y: 0, width: 1, height: 1)

        let fit = LocalVideoRecorder.place(source, rotation: .none, in: tile, canvas: canvas, mode: .fit)
        let fill = LocalVideoRecorder.place(source, rotation: .none, in: tile, canvas: canvas, mode: .fill)

        XCTAssertEqual(fit.extent.width, 400, accuracy: 0.001)
        XCTAssertEqual(fit.extent.height, 200, accuracy: 0.001, "fit never exceeds the target box")
        XCTAssertEqual(fill.extent.width, 400, accuracy: 0.001)
        XCTAssertEqual(fill.extent.height, 400, accuracy: 0.001, "fill crops to the full target box")
    }

    func testStopBeforeStartThrows() async {
        let recorder = LocalVideoRecorder(
            configuration: LocalRecordingConfiguration(outputURL: URL(fileURLWithPath: "/tmp/none.mp4")),
            layoutProvider: { [] }
        )
        do {
            _ = try await recorder.stop()
            XCTFail("stop before start must fail")
        } catch let error as LocalRecordingError {
            XCTAssertEqual(error, .notRecording)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testStartRejectsInvalidConfigurationBeforeEngineLookup() async {
        let badSize = LocalRecordingConfiguration(
            outputURL: URL(fileURLWithPath: "/tmp/bad.mp4"),
            canvasSize: .zero
        )
        let recorder = LocalVideoRecorder(configuration: badSize, layoutProvider: { [] })
        do {
            try await recorder.start()
            XCTFail("zero canvas must fail")
        } catch let error as LocalRecordingError {
            XCTAssertEqual(error, .invalidCanvasSize)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        let badRate = LocalRecordingConfiguration(
            outputURL: URL(fileURLWithPath: "/tmp/bad.mp4"),
            frameRate: 0
        )
        let other = LocalVideoRecorder(configuration: badRate, layoutProvider: { [] })
        do {
            try await other.start()
            XCTFail("zero frame rate must fail")
        } catch let error as LocalRecordingError {
            XCTAssertEqual(error, .invalidFrameRate)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}

final class RecordingAudioMixerTests: XCTestCase {
    private func ingest(
        _ mixer: RecordingAudioMixer,
        _ stream: RecordingAudioMixer.Stream,
        _ values: [Int16],
        at index: Int64
    ) {
        values.withUnsafeBufferPointer { mixer.ingest(stream: stream, samples: $0, startIndex: index) }
    }

    private func drain(_ mixer: RecordingAudioMixer) -> [Int16] {
        var output: [Int16] = []
        while let chunk = mixer.takeSamples(maxCount: 4_800) {
            output.append(contentsOf: chunk.samples)
        }
        return output
    }

    func testMixesBothStreamsAndClipsInsteadOfWrapping() {
        let mixer = RecordingAudioMixer()
        ingest(mixer, .microphone, [1000, -1000, 30_000], at: 0)
        ingest(mixer, .playout, [500, 500, 30_000], at: 0)

        XCTAssertEqual(drain(mixer), [1500, -500, Int16.max])
    }

    func testHoldsOutputUntilBothStreamsArrive() {
        let mixer = RecordingAudioMixer()
        ingest(mixer, .microphone, [Int16](repeating: 100, count: 480), at: 0)
        XCTAssertTrue(drain(mixer).isEmpty, "a one-sided first buffer is held, not guessed")

        ingest(mixer, .playout, [Int16](repeating: 50, count: 480), at: 0)
        XCTAssertEqual(drain(mixer), [Int16](repeating: 150, count: 480))
    }

    /// A mic-only (or playout-only) recording must not stall: once the other side is more
    /// than the 0.5 s gap behind, the mixer releases with silence for the missing side.
    func testMissingStreamIsTreatedAsSilenceAfterTheGap() {
        let mixer = RecordingAudioMixer(sampleRate: 48_000)
        ingest(mixer, .microphone, [Int16](repeating: 10, count: 48_000), at: 0)

        let released = drain(mixer)
        XCTAssertEqual(released.count, 24_000)
        XCTAssertEqual(released.first, 10)

        mixer.finish()
        XCTAssertEqual(drain(mixer).count, 24_000)
    }

    func testLatePacketsAreDroppedInsteadOfRewindingTheTimeline() {
        let mixer = RecordingAudioMixer()
        ingest(mixer, .microphone, [1, 1], at: 0)
        ingest(mixer, .playout, [2, 2], at: 0)
        XCTAssertEqual(drain(mixer), [3, 3])

        ingest(mixer, .microphone, [9], at: 0)
        mixer.finish()

        XCTAssertTrue(drain(mixer).isEmpty)
        XCTAssertGreaterThan(mixer.droppedSamples, 0)
    }
}

final class AudioSampleClockTests: XCTestCase {
    func testOneSecondMapsToSampleRate() {
        let start = HostClock.now
        let later = start + HostClock.hostTime(nanos: 1_000_000_000)
        let clock = AudioSampleClock(startHostTime: start)

        XCTAssertLessThanOrEqual(abs(Int(clock.sampleIndex(forHostTime: later)) - 48_000), 2)
    }

    func testBuffersFromBeforeTheStartClampToZero() {
        let start = HostClock.now
        let clock = AudioSampleClock(startHostTime: start)

        XCTAssertEqual(clock.sampleIndex(forHostTime: start - 1_000), 0)
    }
}

/// End-to-end: the tap feeds PCM, the recorder writes a real MP4, and the file carries both
/// tracks. Runs without an audio unit, which is why `AudioTapSource` exists.
@MainActor
final class LocalRecordingAudioTests: XCTestCase {
    final class FakeTapSource: AudioTapSource {
        var pcmTap: AudioPCMTap?
    }

    private var retainedEngine: StubEngine?

    func testRecordingWritesAnAudioTrackAlongsideVideo() async throws {
        let previous = AudioTapRegistry.source
        let source = FakeTapSource()
        AudioTapRegistry.source = source
        defer { AudioTapRegistry.source = previous }
        // `JitsiMeet.engine` is weak; the test has to hold the stub for the whole run.
        let engine = StubEngine()
        retainedEngine = engine
        JitsiMeet.shared.attach(engine)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("recording-audio-\(UUID().uuidString).mp4")
        defer {
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
            }
        }

        let recorder = LocalVideoRecorder(
            configuration: LocalRecordingConfiguration(
                outputURL: url,
                canvasSize: CGSize(width: 160, height: 120),
                frameRate: 24,
                videoBitrate: 500_000,
                codec: .h264,
                audio: AudioRecordingOptions()
            ),
            layoutProvider: {
                [RecordingTile(trackID: "local", frame: CGRect(x: 0, y: 0, width: 1, height: 1))]
            }
        )

        try await recorder.start()
        let tap = try XCTUnwrap(source.pcmTap, "recorder must install a tap when audio is requested")

        let start = HostClock.now
        for step in 0..<20 {
            let hostTime = start + HostClock.hostTime(nanos: UInt64(step) * 10_000_000)
            let mic = [Int16](repeating: 400, count: 480)
            let playout = [Int16](repeating: 200, count: 480)
            mic.withUnsafeBufferPointer {
                tap.didCapturePCM($0.baseAddress!, frameCount: $0.count, hostTime: hostTime)
            }
            playout.withUnsafeBufferPointer {
                tap.didPlayoutPCM($0.baseAddress!, frameCount: $0.count, hostTime: hostTime)
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        // Let the video pump and the 50 ms audio drain run.
        try await Task.sleep(nanoseconds: 250_000_000)

        let output = try await recorder.stop()
        let asset = AVURLAsset(url: output)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)

        XCTAssertEqual(audioTracks.count, 1)
        XCTAssertEqual(videoTracks.count, 1)

        // The file must actually carry samples, not just an empty track.
        let duration = try await asset.load(.duration)
        XCTAssertGreaterThan(duration.seconds, 0.05)
        XCTAssertNil(source.pcmTap, "stop must release the tap")
    }
}
