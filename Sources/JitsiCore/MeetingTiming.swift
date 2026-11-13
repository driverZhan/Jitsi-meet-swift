import Foundation

/// When the meeting started and how long it may run.
///
/// The anchor mirrors the reference client: the room's `muc#roominfo_created_timestamp`,
/// i.e. when the second occupant joined, so "elapsed" is the meeting's duration rather than
/// this endpoint's time in the room. Deployments without that Prosody module fall back to
/// the server-enforced time limit's own clock and finally to the local join time, and
/// `startSource` says which one is in use.
public struct MeetingTiming: Sendable, Equatable {
    /// Where `startedAt` came from.
    public enum StartSource: String, Sendable {
        /// `muc#roominfo_created_timestamp` (milliseconds since epoch).
        case serverCreated
        /// Reverse-computed from the time-limit message's `elapsedSeconds`.
        case serverRestricted
        /// Server gave nothing; the moment this endpoint reached the room.
        case localJoin
    }

    /// What `timeLimit` represents.
    public enum LimitSource: String, Sendable {
        /// `mod_time_restricted`: the room is destroyed when the limit is reached.
        case serverEnforced
        /// Supplied by the host in `MeetingRequest.meetingTimeLimit`; display only.
        case hostConfigured
    }

    public let startedAt: Date
    public let startSource: StartSource
    /// Seconds the meeting may run; nil when neither the server nor the host knows.
    public let timeLimit: TimeInterval?
    public let limitSource: LimitSource?
    /// The clock the limit is measured from. Usually `startedAt`, but the server's limit is
    /// anchored at room creation while `startedAt` is anchored at the second occupant.
    public let limitStartedAt: Date?
    /// When this value was produced, for `elapsed` / `remaining` on a stored snapshot.
    public let capturedAt: Date

    public init(
        startedAt: Date,
        startSource: StartSource,
        timeLimit: TimeInterval? = nil,
        limitSource: LimitSource? = nil,
        limitStartedAt: Date? = nil,
        capturedAt: Date
    ) {
        self.startedAt = startedAt
        self.startSource = startSource
        self.timeLimit = timeLimit
        self.limitSource = limitSource
        self.limitStartedAt = limitStartedAt
        self.capturedAt = capturedAt
    }

    public var elapsed: TimeInterval { elapsed(at: capturedAt) }
    public var remaining: TimeInterval? { remaining(at: capturedAt) }

    public func elapsed(at date: Date) -> TimeInterval {
        max(0, date.timeIntervalSince(startedAt))
    }

    /// Negative once the meeting is past its limit.
    public func remaining(at date: Date) -> TimeInterval? {
        guard let timeLimit else { return nil }
        return timeLimit - date.timeIntervalSince(limitStartedAt ?? startedAt)
    }

    public func isExpired(at date: Date) -> Bool {
        guard let remaining = remaining(at: date) else { return false }
        return remaining <= 0
    }
}
