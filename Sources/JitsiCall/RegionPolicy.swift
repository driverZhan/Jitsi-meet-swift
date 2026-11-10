import Foundation
import JitsiCore

/// Incoming-call presentation policy.
///
/// The SDK does not link any system call-UI or VoIP-push framework. Every build presents an
/// invite with `SystemInterruptionPresenter`:
///
/// * app active -> `CallOverlayView` in an overlay window, showing the caller, the conference
///   name and answer/decline without leaving the app;
/// * anything else -> a local notification with `ANSWER` / `DECLINE` action buttons, a custom
///   sound, and lock-screen delivery;
/// * offline wake -> the integrator's APNs **alert** push (a visible banner), handed to
///   `CallCenter.report(_:)`; no VoIP push and no extra entitlement.
///
/// The consequence to design around: a backgrounded build cannot join the conference before
/// the user taps. Answering therefore starts the engine after the tap, which is why
/// `CallCenter` hands back a decision instead of a pre-warmed session.
public enum RegionPolicy {
    /// Presentation strategy used by every build.
    ///
    /// `region` is kept in the signature for source compatibility; presentation no longer
    /// varies by region.
    @MainActor
    public static func presenter(for _: SDKConfig.Region) -> IncomingCallPresenting {
        SystemInterruptionPresenter()
    }

    /// Diagnostics string: what a user will actually see.
    public static func describe(for _: SDKConfig.Region) -> String {
        "notification + in-app overlay"
    }
}
