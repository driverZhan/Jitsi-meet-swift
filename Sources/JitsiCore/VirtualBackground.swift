import CoreGraphics
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// What the local camera shows around the participant.
///
/// This is applied natively to the camera frames between capture and encoding: the person
/// is segmented with Vision, the surroundings are blurred or replaced by a still image, and
/// the result is what the sender encodes. No SDP, track or room state changes, so switching
/// the effect never renegotiates the call and lib-jitsi-meet is not involved at all.
public enum VirtualBackgroundMode {
    /// Camera frame as captured (the default).
    case none
    /// Blurs the surroundings of the person. `strength` is 0...1 and is clamped.
    case blur(strength: Double)
    /// Replaces the surroundings with a still image, aspect-filled to the camera frame.
    case image(CGImage)

    /// Noticeable blur without turning the room into mud.
    public static let defaultBlur = VirtualBackgroundMode.blur(strength: 0.5)

    public var isEnabled: Bool {
        if case .none = self { return false }
        return true
    }

    /// Clamped 0...1 for `.blur`; nil for the other modes.
    public var blurStrength: Double? {
        guard case .blur(let strength) = self else { return nil }
        return min(max(strength, 0), 1)
    }

    /// The still image for `.image`; nil for the other modes.
    public var image: CGImage? {
        guard case .image(let image) = self else { return nil }
        return image
    }

    /// Stable name for logs and ObjC status dictionaries.
    public var name: String {
        switch self {
        case .none: return "none"
        case .blur: return "blur"
        case .image: return "image"
        }
    }
}

#if canImport(UIKit)
public enum VirtualBackgroundImages {
    /// Normalises a UIKit image into a `CGImage` the effect can composite.
    ///
    /// Photos come from the library with a `UIImage.Orientation` instead of rotated pixels,
    /// and `CGImage` carries no orientation, so the drawing below bakes it in. Large pictures
    /// are downscaled to `maxDimension`; the frame they replace is at most a few megapixels.
    public static func cgImage(from image: UIImage, maxDimension: CGFloat = 1920) -> CGImage? {
        // `UIImage.size` is already orientation-aware, so a portrait photo carries its upright
        // dimensions here and the canvas below keeps the right aspect ratio.
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let longest = max(size.width, size.height)
        let scale = longest > maxDimension ? maxDimension / longest : 1
        let target = CGSize(
            width: (size.width * scale).rounded(),
            height: (size.height * scale).rounded())
        guard target.width >= 1, target.height >= 1 else { return nil }
        let format = UIGraphicsImageRendererFormat.default()
        // 1: the picture is not a Retina layout artifact, and the compositor asks for pixels.
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let normalized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return normalized.cgImage
    }
}
#endif
