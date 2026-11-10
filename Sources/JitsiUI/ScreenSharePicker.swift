#if canImport(ReplayKit)
import JitsiMedia
import ReplayKit
import SwiftUI

/// The system control that starts a broadcast. iOS only lets the user start screen
/// sharing from `RPSystemBroadcastPickerView` (or Control Center); there is no API to
/// launch the broadcast programmatically.
///
/// Set `ScreenShareConfiguration.extensionBundleIdentifier` to the broadcast upload
/// extension's bundle id so the picker preselects it.
public struct ScreenShareBroadcastPicker: UIViewRepresentable {
    public init() {}

    public func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let view = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 48, height: 48))
        view.preferredExtension = ScreenShareConfiguration.extensionBundleIdentifier
        view.showsMicrophoneButton = false
        return view
    }

    public func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {
        uiView.preferredExtension = ScreenShareConfiguration.extensionBundleIdentifier
    }
}
#endif
