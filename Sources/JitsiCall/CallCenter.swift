import Foundation
import JitsiCore

/// Turns "someone wants you in a conference" into a presented call and a decision.
///
/// ## Delivery, since PushKit is off the table in the mainland build
///
/// There is no system VoIP channel to receive, so `CallCenter` accepts invites through two
/// doors and treats them identically:
///
/// * `listenForEngineInvites()` -- the signaling connection the SDK already holds. An
///   endpoint message with `{ "type": "invite", ... }` arrives on the live XMPP/WebSocket or
///   bridge channel, which is the only path that works while the app is foregrounded or
///   briefly suspended, and it needs no extra entitlement.
/// * `report(_:)` -- whatever out-of-band transport the integrator has: an APNs **alert**
///   push (allowed to show a banner, and does not require `PKPushRegistry`), a vendor push
///   channel, or the app's own presence service.
///
/// The trade-off to plan for: an alert push cannot launch the app into an active conference,
/// so an invite that arrives while the device is locked is presented as a notification and the
/// join happens after the user taps. That is precisely the behaviour CallKit would have hidden,
/// and it is why `decisions` reports the decision rather than a pre-warmed session.
@MainActor
public final class CallCenter: ObservableObject {
    public let region: SDKConfig.Region

    /// Every decision, in order, with the call it belongs to.
    public var decisions: AsyncStream<(IncomingCall, CallDecision)> { decisionStream }

    /// Presentation strategy in use, for diagnostics and UI copy.
    public let strategyName: String

    private let presenter: IncomingCallPresenting
    private let decisionStream: AsyncStream<(IncomingCall, CallDecision)>
    private var decisionContinuation: AsyncStream<(IncomingCall, CallDecision)>.Continuation?
    private var ringing: [String: Task<CallDecision, Never>] = [:]
    private var hubSubscription: Subscription?

    public init(region: SDKConfig.Region) {
        self.region = region
        presenter = RegionPolicy.presenter(for: region)
        strategyName = presenter.strategyName

        var captured: AsyncStream<(IncomingCall, CallDecision)>.Continuation?
        decisionStream = AsyncStream(bufferingPolicy: .unbounded) { captured = $0 }
        decisionContinuation = captured

        presenter.prepare()
    }

    // MARK: - Invites

    /// Reads invite-shaped endpoint messages off the shared event hub.
    ///
    /// `MeetingEvent.endpointMessage` is where lib-jitsi-meet surfaces application-defined
    /// JSON on the bridge data channel, so no extra XMPP handling is needed in Swift.
    public func listenForEngineInvites() {
        hubSubscription?.unsubscribe()
        hubSubscription = JitsiMeet.shared.events.subscribe { [weak self] event in
            guard case .endpointMessage(let from, let content) = event,
                  content["type"]?.stringValue == "invite"
            else { return }
            let call = IncomingCall(
                conference: content["conference"]?.stringValue ?? "",
                callerName: content["displayName"]?.stringValue ?? from ?? "Guest",
                callerJID: from,
                avatarURL: content["avatar"]?.stringValue,
                token: content["token"]?.stringValue
            )
            guard !call.conference.isEmpty else { return }
            Task { @MainActor in await self?.report(call) }
        }
    }

    /// Present an invite from any transport and wait for the user's decision.
    @discardableResult
    public func report(_ call: IncomingCall) async -> CallDecision {
        if let task = ringing[call.id] {
            return await task.value
        }
        let presenter = self.presenter
        let task = Task { await presenter.present(call) }
        ringing[call.id] = task
        let decision = await task.value
        ringing[call.id] = nil
        decisionContinuation?.yield((call, decision))
        return decision
    }

    public func cancel(callID: String) {
        presenter.dismiss(callID: callID)
        ringing[callID] = nil
    }

    public func stopRinging() {
        for callID in ringing.keys {
            cancel(callID: callID)
        }
    }

    // MARK: - Diagnostics

    /// What the user will actually see for an incoming call in this build.
    public func presentationDescription() -> String {
        RegionPolicy.describe(for: region)
    }

    public var canRegisterPushKitToken: Bool {
        RegionPolicy.allowsPushKit(for: region)
    }
}
