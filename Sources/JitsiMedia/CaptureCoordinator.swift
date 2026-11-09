import AVFoundation
import Foundation
import JitsiCore

/// Device discovery and permission prompts. Replaces the browser's
/// `navigator.mediaDevices.enumerateDevices()` / `getUserMedia()` permission model.
public final class CaptureCoordinator: @unchecked Sendable {
    public init() {}

    public func requestAccess(for mediaTypes: [MediaType]) async -> [MediaType: Bool] {
        var granted: [MediaType: Bool] = [:]
        for mediaType in mediaTypes {
            let avMediaType: AVMediaType = mediaType == .audio ? .audio : .video
            switch AVCaptureDevice.authorizationStatus(for: avMediaType) {
            case .authorized:
                granted[mediaType] = true
            case .notDetermined:
                granted[mediaType] = await withCheckedContinuation { continuation in
                    AVCaptureDevice.requestAccess(for: avMediaType) { granted in
                        continuation.resume(returning: granted)
                    }
                }
            default:
                granted[mediaType] = false
            }
        }
        return granted
    }

    public func enumerate() -> [DeviceDescriptor] {
        var devices: [DeviceDescriptor] = []

        let videoSession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInTelephotoCamera, .builtInUltraWideCamera],
            mediaType: .video,
            position: .unspecified
        )
        for device in videoSession.devices where device.hasMediaType(.video) {
            devices.append(DeviceDescriptor(
                id: device.uniqueID,
                kind: .video,
                label: device.localizedName,
                facing: Self.facing(of: device)
            ))
        }

        let audioSession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInMicrophone],
            mediaType: .audio,
            position: .unspecified
        )
        for device in audioSession.devices {
            devices.append(DeviceDescriptor(
                id: device.uniqueID,
                kind: .audio,
                label: device.localizedName,
                facing: .unspecified
            ))
        }
        return devices
    }

    private static func facing(of device: AVCaptureDevice) -> DeviceDescriptor.CameraFacing {
        switch device.position {
        case .front: return .user
        case .back: return .environment
        default: return .unspecified
        }
    }

    /// Screen capture is ReplayKit, not a capture device: it arrives from a broadcast
    /// upload extension over an app-group socket and is injected as a synthetic track.
    public func isScreenCaptureAvailable() -> Bool {
        ProcessInfo.processInfo.environment["JITSI_SCREEN_CAPTURE_AVAILABLE"] != nil
    }
}
