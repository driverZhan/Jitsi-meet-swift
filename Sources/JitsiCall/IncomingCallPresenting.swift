import Foundation
import JitsiCore

/// An invitation that has to be surfaced to the user before the conference is joined.
public struct IncomingCall: Sendable, Equatable {
    public let id: String
    public let conference: ConferenceName
    public let callerName: String
    public let callerJID: String?
    public let avatarURL: String?
    /// JWT or lobby code needed to join, when the inviter passed one.
    public let token: String?
    public let receivedAt: Date

    public init(
        id: String = UUID().uuidString,
        conference: ConferenceName,
        callerName: String,
        callerJID: String? = nil,
        avatarURL: String? = nil,
        token: String? = nil,
        receivedAt: Date = Date()
    ) {
        self.id = id
        self.conference = conference
        self.callerName = callerName
        self.callerJID = callerJID
        self.avatarURL = avatarURL
        self.token = token
        self.receivedAt = receivedAt
    }
}

public enum CallDecision: String, Sendable {
    case accepted
    case declined
    case timedOut
    case superseded
}

/// What a presentation strategy must be able to do.
///
/// Implementations differ only in *how* the user is interrupted, never in what a call is,
/// which is why the rest of the SDK does not know CallKit exists. Main-actor confined: every
/// strategy here owns UI or a system UI surrogate, and CallKit itself requires the main
/// thread, so there is nothing to gain from spreading the work across executors.
@MainActor
public protocol IncomingCallPresenting: AnyObject {
    /// Human-readable reason this strategy is used, surfaced in diagnostics.
    var strategyName: String { get }

    /// Idempotent: registers notification categories, requests authorization, or creates the
    /// CallKit provider, depending on the strategy.
    func prepare()

    /// Suspends until the user (or the timeout) decides.
    func present(_ call: IncomingCall) async -> CallDecision

    func dismiss(callID: String)
}
