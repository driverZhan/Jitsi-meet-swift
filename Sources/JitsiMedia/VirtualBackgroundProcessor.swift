import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Foundation
import JitsiCore
import Vision

/// Segments the participant on the camera frames and replaces everything else.
///
/// Runs on the capture queue, one pass per frame: the effect has to follow the picture in
/// real time, so a background that lags the person would look worse than no effect at all.
/// `balanced` person segmentation is the only quality level that holds ~30 fps on a phone;
/// `accurate` costs multiples of that for a mask no one sees at video resolution.
///
/// Every method is called from the capture queue only; nothing here is thread-safe on its
/// own.
final class VirtualBackgroundProcessor {
    private let context: CIContext
    private let handler = VNSequenceRequestHandler()
    private let request = VNGeneratePersonSegmentationRequest()
    /// Output buffers come from a pool so the encoder is not paying a fresh CoreVideo
    /// allocation on every frame.
    private var pool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0
    /// Logs the first Vision failure only; a device without ANE can fail once per frame and
    /// would otherwise flood the console.
    private var reportedFailure = false

    init() {
        context = CIContext(options: [.cacheIntermediates: false])
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
    }

    /// Returns a composited BGRA buffer, or nil when the frame could not be processed (no
    /// mask, unreadable input); the caller then forwards the untouched camera frame.
    func process(_ pixelBuffer: CVPixelBuffer, mode: VirtualBackgroundMode) -> CVPixelBuffer? {
        guard mode.isEnabled else { return nil }
        do {
            try handler.perform([request], on: pixelBuffer, orientation: .up)
        } catch {
            if !reportedFailure {
                reportedFailure = true
                NSLog("[virtual-background] person segmentation failed: %@", error.localizedDescription)
            }
            return nil
        }
        guard let maskBuffer = request.results?.first?.pixelBuffer else { return nil }

        let source = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = source.extent
        guard extent.width >= 1, extent.height >= 1 else { return nil }
        let mask = CIImage(cvPixelBuffer: maskBuffer)
        guard mask.extent.width >= 1, mask.extent.height >= 1 else { return nil }

        switch mode {
        case .none:
            return nil
        case .blur(let strength):
            let sigma = Self.blurSigma(strength: strength, width: extent.width)
            let background = source
                .clampedToExtent()
                .applyingGaussianBlur(sigma: sigma)
                .cropped(to: extent)
            return composite(source: source, background: background, mask: mask, extent: extent)
        case .image(let image):
            let background = Self.aspectFill(CIImage(cgImage: image), to: extent)
            return composite(source: source, background: background, mask: mask, extent: extent)
        }
    }

    private func composite(
        source: CIImage,
        background: CIImage,
        mask: CIImage,
        extent: CGRect
    ) -> CVPixelBuffer? {
        guard let output = Self.blended(
                  source: source, background: background, mask: mask, extent: extent),
              let buffer = makeBuffer(width: Int(extent.width), height: Int(extent.height))
        else { return nil }
        context.render(
            output,
            to: buffer,
            bounds: extent,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return buffer
    }

    /// Puts the person back over the replacement background.
    ///
    /// `CIBlendWithMask` shows `inputImage` where the mask is white and `backgroundImage`
    /// where it is black. Vision paints the person white, so the untouched frame is the input
    /// and the blur or picture is the background; inverted, the participant is what gets
    /// blurred and the room stays sharp.
    ///
    /// Internal rather than private: the polarity is the one thing here that fails silently
    /// and looks like a design choice, so the test target drives this with synthetic images.
    static func blended(
        source: CIImage,
        background: CIImage,
        mask: CIImage,
        extent: CGRect
    ) -> CIImage? {
        guard mask.extent.width >= 1, mask.extent.height >= 1 else { return nil }
        // Vision returns the mask at its own resolution; CIBlendWithMask needs it in the
        // frame's coordinate space, otherwise the person is cut out at the wrong position.
        let scaledMask = mask
            .transformed(by: CGAffineTransform(
                scaleX: extent.width / mask.extent.width,
                y: extent.height / mask.extent.height))
            .cropped(to: extent)
        let blend = CIFilter.blendWithMask()
        blend.inputImage = source
        blend.backgroundImage = background
        blend.maskImage = scaledMask
        return blend.outputImage
    }

    /// Blur is expressed in pixels of the current frame, so a 360p and a 720p preview look
    /// the same instead of one being sharp and the other unrecognisable.
    private static func blurSigma(strength: Double, width: CGFloat) -> Double {
        let clamped = min(max(strength, 0), 1)
        return max(6, Double(width) * 0.015 * (0.4 + 1.2 * clamped))
    }

    /// Scales `image` to cover `extent` and centres it, which is how a phone background is
    /// expected to fill a landscape frame.
    private static func aspectFill(_ image: CIImage, to extent: CGRect) -> CIImage {
        let size = image.extent.size
        guard size.width >= 1, size.height >= 1 else { return image }
        let scale = max(extent.width / size.width, extent.height / size.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let deltaX = extent.midX - scaled.extent.midX
        let deltaY = extent.midY - scaled.extent.midY
        return scaled
            .transformed(by: CGAffineTransform(translationX: deltaX, y: deltaY))
            .cropped(to: extent)
    }

    /// BGRA is one of the pixel formats `RTCCVPixelBuffer` accepts directly, so the composited
    /// frames go back into the capture path without another conversion step.
    private func makeBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        if pool == nil || poolWidth != width || poolHeight != height {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
                kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            ]
            var created: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(
                kCFAllocatorDefault, nil, attributes as CFDictionary, &created
            ) == kCVReturnSuccess, let created else {
                return nil
            }
            pool = created
            poolWidth = width
            poolHeight = height
        }
        guard let pool else { return nil }
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault, pool, &pixelBuffer
        ) == kCVReturnSuccess else {
            return nil
        }
        return pixelBuffer
    }
}
