#if JITSI_ENABLE_CALLKIT
import AVFoundation
import CallKit
import JitsiCore
import UIKit
import UserNotifications

/// International-build presentation: the system ring UI.
///
/// Compiled only with the `JITSI_ENABLE_CALLKIT` flag (see `Package.swift`), so a mainland
/// artifact cannot contain the symbols at all. The wire-up the integrator still owns:
///
/// * a PushKit token (`PKPushRegistry`) and a `pushRegistry(_:didReceive:for:)` handler that
///   calls `CallCenter.report(_:)`;
/// * the CallKit entitlement and, for App Review, a stated VoIP use case;
/// * an app-provided `templateIcon`, since `iconTemplateImageData` is deprecated;
/// * audio: CallKit owns the audio unit, so `AudioSessionManager.beginConference` has to run
///   from `provider(_:didActivate:)` rather than at join time.
@available(iOS 14.0, *)
@MainActor
public final class CallKitPresenter: NSObject, IncomingCallPresenting, @preconcurrency CXProviderDelegate {
    public let strategyName = "CallKit system UI"

    /// Ringing window; CallKit applies its own system timeout on top of this.
    public var ringTimeout: TimeInterval = 24

    private let provider = CXProvider(configuration: CallKitPresenter.makeConfiguration())
    private var pending: [UUID: CheckedContinuation<CallDecision, Never>] = [:]
    private var timeouts: [UUID: Task<Void, Never>] = [:]

    public override init() {
        super.init()
        // nil queue => delegate callbacks arrive on the main queue, which is where this
        // class keeps its state.
        provider.setDelegate(self, queue: nil)
    }

    public func prepare() {
        let answer = UNNotificationAction(identifier: "answer", title: "Answer", options: [.foreground])
        let decline = UNNotificationAction(identifier: "decline", title: "Decline", options: [.destructive])
        UNUserNotificationCenter.current().setNotificationCategories([UNNotificationCategory(
            identifier: "com.jitsi.call.incoming",
            actions: [answer, decline],
            intentIdentifiers: []
        )])
    }

    public func present(_ call: IncomingCall) async -> CallDecision {
        let uuid = UUID(uuidString: call.id) ?? UUID()
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: call.callerJID ?? call.callerName)
        update.localizedCallerName = call.callerName
        update.hasVideo = true
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false

        let limit = max(ringTimeout, 1)
        return await withCheckedContinuation { continuation in
            pending[uuid] = continuation
            timeouts[uuid] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.finish(uuid: uuid, decision: .timedOut, endCall: true)
            }
            provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
                guard let self, error != nil else { return }
                // The system UI never appeared; resolve rather than hang until the timeout.
                Task { @MainActor in self.finish(uuid: uuid, decision: .declined, endCall: false) }
            }
        }
    }

    public func dismiss(callID: String) {
        guard let uuid = UUID(uuidString: callID) else { return }
        finish(uuid: uuid, decision: .superseded, endCall: true)
    }

    private func finish(uuid: UUID, decision: CallDecision, endCall: Bool) {
        timeouts.removeValue(forKey: uuid)?.cancel()
        if endCall {
            provider.reportCall(with: uuid, endedAt: Date(), reason: .remoteEnded)
        }
        pending.removeValue(forKey: uuid)?.resume(returning: decision)
    }

    // MARK: - CXProviderDelegate

    public func providerDidReset(_ provider: CXProvider) {
        for uuid in Array(pending.keys) {
            finish(uuid: uuid, decision: .timedOut, endCall: false)
        }
    }

    public func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        // Answering is only the decision to join; the conference itself starts in the app
        // once `CallCenter.decisions` publishes `.accepted`.
        if let continuation = pending.removeValue(forKey: action.callUUID) {
            continuation.resume(returning: .accepted)
        }
        timeouts.removeValue(forKey: action.callUUID)?.cancel()
        action.fulfill()
    }

    public func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        if let continuation = pending.removeValue(forKey: action.callUUID) {
            timeouts.removeValue(forKey: action.callUUID)?.cancel()
            continuation.resume(returning: .declined)
        } else {
            // Already answered: tearing the system UI down is the app's job from here.
            provider.reportCall(with: action.callUUID, endedAt: Date(), reason: .remoteEnded)
        }
        action.fulfill()
    }

    /// CallKit owns the audio unit for the ring; hand it back once the system activates it.
    public func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        NSLog("[jitsi-call] CallKit activated the audio session")
    }

    public func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        NSLog("[jitsi-call] CallKit deactivated the audio session")
    }

    private static func makeConfiguration() -> CXProviderConfiguration {
        let config = CXProviderConfiguration()
        config.supportsVideo = true
        config.maximumCallGroups = 1
        config.maximumCallsPerCallGroup = 1
        config.includesCallsInRecents = false
        config.ringtoneSound = "incoming.caf"
        config.supportedHandleTypes = [.generic]
        return config
    }
}
#endif
