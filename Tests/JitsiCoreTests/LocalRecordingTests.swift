import CoreGraphics
import CoreVideo
import JitsiCore
import JitsiMedia
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
