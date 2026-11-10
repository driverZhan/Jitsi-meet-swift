import Foundation
import JitsiCore
import SwiftUI
import UIKit
import UserNotifications

/// Incoming-call presentation used by every build: notification + in-app overlay.
///
/// Two interruption surfaces, chosen by the app's own state at the moment the invite
/// arrives, because that is the signal available without a system call UI:
///
/// * active app -> `CallOverlayView` in an overlay window, showing the caller, the conference
///   name and answer/decline without leaving the app;
/// * anything else -> a local notification with `ANSWER` / `DECLINE` actions and a custom
///   sound, which also reaches the lock screen.
///
/// Both paths resolve the same `CallDecision`, so `CallCenter` and the rest of the SDK stay
/// unaware of which surface the user used.
@MainActor
public final class SystemInterruptionPresenter: NSObject, IncomingCallPresenting {
    public let strategyName = "system notification + in-app overlay"

    public static let categoryIdentifier = "com.jitsi.call.incoming"
    public static let answerAction = "com.jitsi.call.answer"
    public static let declineAction = "com.jitsi.call.decline"
    public static let callIDKey = callNotificationIDKey

    /// Ringing window; after it the decision is `timedOut`.
    public var ringTimeout: TimeInterval = 30

    private var overlay = CallOverlayController()
    private var pending: [String: CheckedContinuation<CallDecision, Never>] = [:]
    private var timeouts: [String: Task<Void, Never>] = [:]
    private var authorized = false
    private var prepared = false

    public override init() {}

    public func prepare() {
        guard !prepared else { return }
        prepared = true

        let center = UNUserNotificationCenter.current()
        CallNotificationBridge.shared.presenter = self
        center.delegate = CallNotificationBridge.shared

        let answer = UNNotificationAction(
            identifier: Self.answerAction,
            title: "Answer",
            options: [.foreground]
        )
        let decline = UNNotificationAction(
            identifier: Self.declineAction,
            title: "Decline",
            options: [.destructive]
        )
        center.setNotificationCategories([UNNotificationCategory(
            identifier: Self.categoryIdentifier,
            actions: [answer, decline],
            intentIdentifiers: []
        )])

        Task {
            switch (await center.notificationSettings()).authorizationStatus {
            case .notDetermined:
                authorized = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            case .denied:
                authorized = false
            default:
                authorized = true
            }
        }
    }

    public func present(_ call: IncomingCall) async -> CallDecision {
        prepare()
        if UIApplication.shared.applicationState == .active {
            return await presentOverlay(call)
        }
        return await presentNotification(call)
    }

    public func dismiss(callID: String) {
        resolve(callID, with: .superseded)
    }

    func resolve(_ callID: String, with decision: CallDecision) {
        timeouts.removeValue(forKey: callID)?.cancel()
        timeouts[callID] = nil
        if callID == overlay.callID {
            overlay.hide()
        }
        pending.removeValue(forKey: callID)?.resume(returning: decision)
    }

    /// Notification actions land here on the main queue, from the shared bridge delegate.
    func handle(actionIdentifier: String, callID: String) {
        switch actionIdentifier {
        case Self.answerAction, UNNotificationDefaultActionIdentifier:
            // Opening the app from the banner is treated as accepting: the app is the only
            // place the decision can be recorded, since there is no system call UI.
            resolve(callID, with: .accepted)
        default:
            resolve(callID, with: .declined)
        }
    }

    // MARK: - Surfaces

    private func presentOverlay(_ call: IncomingCall) async -> CallDecision {
        return await withCheckedContinuation { continuation in
            pending[call.id] = continuation
            armTimeout(call.id)
            overlay.show(
                call: call,
                onAnswer: { [weak self] in self?.resolve(call.id, with: .accepted) },
                onDecline: { [weak self] in self?.resolve(call.id, with: .declined) }
            )
        }
    }

    private func presentNotification(_ call: IncomingCall) async -> CallDecision {
        let content = UNMutableNotificationContent()
        content.title = call.callerName
        content.body = "Incoming meeting: \(call.conference)"
        content.categoryIdentifier = Self.categoryIdentifier
        content.userInfo = [Self.callIDKey: call.id]
        if authorized {
            content.sound = UNNotificationSound(named: UNNotificationSoundName("incoming.caf"))
        }

        return await withCheckedContinuation { continuation in
            pending[call.id] = continuation
            armTimeout(call.id)
            Task {
                try? await UNUserNotificationCenter.current().add(
                    UNNotificationRequest(identifier: call.id, content: content, trigger: nil)
                )
            }
        }
    }

    private func armTimeout(_ callID: String) {
        let limit = ringTimeout
        timeouts[callID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(limit, 1) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.resolve(callID, with: .timedOut)
        }
    }
}

/// userInfo key that ties a notification response back to a ringing call. File-level so
/// the delegate, which is not main-actor isolated, can read it.
let callNotificationIDKey = "callID"

/// Stable delegate object: `UNUserNotificationCenter` keeps one weak delegate, while a
/// presenter belongs to a `CallCenter`, so the delegate routes to whoever is ringing.
final class CallNotificationBridge: NSObject, UNUserNotificationCenterDelegate {
    static let shared = CallNotificationBridge()

    weak var presenter: SystemInterruptionPresenter?

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // The overlay already covers the active app; the banner only matters while the app is
        // transitioning to the foreground after an answer.
        completionHandler([.list, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let actionIdentifier = response.actionIdentifier
        completionHandler()
        guard let callID = userInfo[callNotificationIDKey] as? String else { return }
        Task { @MainActor in
            presenter?.handle(actionIdentifier: actionIdentifier, callID: callID)
        }
    }
}
