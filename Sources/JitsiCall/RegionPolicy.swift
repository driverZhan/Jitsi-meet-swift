import Foundation
import JitsiCore

/// Region gate for incoming-call presentation.
///
/// ## Why CallKit is not an option in the mainland build
///
/// CallKit puts the answer UI and the audio unit under the system's control, which requires
/// the app to be distributed with a VoIP service (CallKit entitlement + PushKit token) and to
/// answer through the system phone UI. Apps distributed in mainland China are not allowed to
/// expose that surface, and Apple additionally requires VoIP pushes (`PKPushTypeVoIP`) to be
/// used only for real VoIP, which a conference SDK cannot rely on for App Store review in
/// that market. So the mainland build:
///
/// * never links or references `CXProvider` / `PKPushRegistry`;
/// * keeps its own signaling connection as the delivery channel (XMPP over the already-open
///   WebSocket, which works in the foreground and while the app is briefly suspended);
/// * uses an ordinary user-visible local notification with `ANSWER` / `DECLINE` action buttons,
///   a custom sound, and (when the app is foregrounded) a full-screen in-app overlay;
/// * uses an APNs **alert** notification (not VoIP) as the offline wake path, because an alert
///   is allowed to carry a user-visible banner and does not need `PKPushRegistry`.
///
/// The consequence to design around: a backgrounded mainland build cannot join the conference
/// before the user taps, and cannot light the screen or take the audio route from the lock
/// screen the way CallKit does. Answering therefore starts the engine after the tap, which is
/// why `CallCenter` hands back a decision instead of a pre-warmed session.
///
/// ## International build
///
/// `JITSI_ENABLE_CALLKIT` is a compile-time switch (see `Package.swift`). When it is set, the
/// region policy returns `CallKitPresenter` and the app may register a PushKit token; the
/// same `IncomingCall` / `CallDecision` contract is used, so nothing else changes.
public enum RegionPolicy {
    /// Which interruption the device allows, resolved once per launch.
    @MainActor
    public static func presenter(for region: SDKConfig.Region) -> IncomingCallPresenting {
        switch region {
        case .chinaMainland:
            // Belt and braces: the CallKit symbols are not in the binary at all unless the
            // flag was set, and the mainland branch never constructs them even when it was.
            return SystemInterruptionPresenter()
        case .international:
            #if JITSI_ENABLE_CALLKIT
            return CallKitPresenter()
            #else
            return SystemInterruptionPresenter()
            #endif
        }
    }

    /// Whether the build is allowed to register a PushKit token. The mainland answer is
    /// always false, including when CallKit happens to be compiled in.
    public static func allowsPushKit(for region: SDKConfig.Region) -> Bool {
        #if JITSI_ENABLE_CALLKIT
        return region == .international
        #else
        return false
        #endif
    }

    /// Diagnostics string: what a user will actually see, and why.
    public static func describe(for region: SDKConfig.Region) -> String {
        switch region {
        case .chinaMainland:
            return "notification + in-app overlay (CallKit excluded from this build)"
        case .international:
            #if JITSI_ENABLE_CALLKIT
            return "CallKit system UI"
            #else
            return "notification + in-app overlay (built without JITSI_ENABLE_CALLKIT)"
            #endif
        }
    }
}
