import CoreGraphics
import CoreImage
import JitsiCore
import JitsiMeetExample
import JitsiUI
import UIKit
import XCTest
@testable import JitsiMedia

/// The frames themselves need a camera, so these cover the two seams around them: the mode
/// routing (session → conference → engine) and the mask polarity of the compositor, which is
/// the part that fails silently and looks like a deliberate effect.
@MainActor
final class VirtualBackgroundTests: XCTestCase {
    private var engine: StubEngine?

    override func setUp() async throws {
        engine = StubEngine()
        JitsiMeet.shared.attach(engine!)
    }

    override func tearDown() async throws {
        engine = nil
        for _ in 0..<50 where JitsiMeet.shared.engine != nil {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertNil(JitsiMeet.shared.engine)
    }

    func testBlurStrengthIsClampedAndNamed() {
        XCTAssertEqual(VirtualBackgroundMode.blur(strength: 2).blurStrength, 1)
        XCTAssertEqual(VirtualBackgroundMode.blur(strength: -1).blurStrength, 0)
        XCTAssertEqual(VirtualBackgroundMode.defaultBlur.name, "blur")
        XCTAssertEqual(VirtualBackgroundMode.none.name, "none")
        XCTAssertFalse(VirtualBackgroundMode.none.isEnabled)
        XCTAssertTrue(VirtualBackgroundMode.defaultBlur.isEnabled)
        XCTAssertNil(VirtualBackgroundMode.none.image)
    }

    func testConferenceForwardsTheModeToTheEngine() async throws {
        let room = JitsiConference(options: JitsiMeetDemo.conference(room: "demo-room"))
        try await room.setVirtualBackground(.defaultBlur)
        XCTAssertEqual(engine?.virtualBackgrounds.count, 1)
        XCTAssertEqual(engine?.virtualBackgrounds.last?.blurStrength, 0.5)
        XCTAssertEqual(room.virtualBackground.name, "blur")

        try await room.setVirtualBackground(.none)
        XCTAssertEqual(engine?.virtualBackgrounds.last?.isEnabled, false)
        XCTAssertEqual(room.virtualBackground.name, "none")
    }

    func testSessionForwardsBlurAndImage() async {
        let model = MeetingSession()
        await model.start(
            JitsiMeetDemo.connection(host: "meet.example.org"),
            conference: JitsiMeetDemo.conference(room: "demo-room", displayName: "Demo"),
            capture: []
        )

        model.setBackgroundBlurEnabled(true)
        await waitUntil { model.virtualBackground.name == "blur" }
        XCTAssertEqual(engine?.virtualBackgrounds.first?.name, "blur")
        XCTAssertEqual(model.virtualBackground.name, "blur")

        let image = VirtualBackgroundImages.cgImage(from: Self.solidImage())
        XCTAssertNotNil(image)
        model.setBackgroundImage(image)
        await waitUntil { model.virtualBackground.name == "image" }
        XCTAssertEqual(engine?.virtualBackgrounds.count, 2)
        XCTAssertEqual(engine?.virtualBackgrounds.last?.name, "image")

        model.setBackgroundImage(nil)
        await waitUntil { self.engine?.virtualBackgrounds.count == 3 }
        XCTAssertEqual(engine?.virtualBackgrounds.last?.isEnabled, false)
        await model.leave()
    }

    func testUIKitImageIsNormalisedToARightSizedCGImage() {
        // 4000x2000 with a 90° orientation: the normaliser has to bake the rotation in and
        // cap the long edge, otherwise a photo-library shot reaches the compositor sideways
        // and several times the size of the frame it replaces.
        let source = Self.solidImage(size: CGSize(width: 4000, height: 2000), orientation: .right)
        let cgImage = VirtualBackgroundImages.cgImage(from: source)
        XCTAssertNotNil(cgImage)
        XCTAssertEqual(cgImage?.height, 1920)
        XCTAssertEqual(cgImage?.width, 960)
    }

    /// Regression: the mask polarity was inverted once, so the participant was what got
    /// blurred and the room stayed sharp. Whoever the mask calls the person must keep the
    /// camera frame.
    func testPersonComesFromTheCameraAndSurroundingsFromTheReplacement() throws {
        let extent = CGRect(x: 0, y: 0, width: 8, height: 8)
        let person = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: extent)
        let replacement = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: extent)
        // A 4x4 mask with a white square in the middle: the blend also has to scale it up.
        let maskExtent = CGRect(x: 0, y: 0, width: 4, height: 4)
        let mask = CIImage(color: .white)
            .cropped(to: CGRect(x: 1, y: 1, width: 2, height: 2))
            .composited(over: CIImage(color: .black).cropped(to: maskExtent))
            .cropped(to: maskExtent)

        let output = try XCTUnwrap(VirtualBackgroundProcessor.blended(
            source: person, background: replacement, mask: mask, extent: extent))
        var pixels = [UInt8](repeating: 0, count: 8 * 8 * 4)
        CIContext(options: [.useSoftwareRenderer: true]).render(
            output,
            toBitmap: &pixels,
            rowBytes: 8 * 4,
            bounds: extent,
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB())

        func pixel(_ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
            let offset = (y * 8 + x) * 4
            return (pixels[offset], pixels[offset + 1], pixels[offset + 2])
        }

        let center = pixel(4, 4)
        XCTAssertGreaterThan(center.r, 200, "person must keep the camera frame")
        XCTAssertLessThan(center.g, 50)
        XCTAssertLessThan(center.b, 50)

        let corner = pixel(0, 0)
        XCTAssertLessThan(corner.r, 50, "surroundings must be replaced, not the person")
        XCTAssertGreaterThan(corner.b, 200)
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<300 {
            if predicate() { return }
            await Task.yield()
        }
    }

    private static func solidImage(
        size: CGSize = CGSize(width: 40, height: 30),
        orientation: UIImage.Orientation = .up
    ) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        guard orientation != .up,
              let cgImage = image.cgImage else { return image }
        return UIImage(cgImage: cgImage, scale: 1, orientation: orientation)
    }
}
