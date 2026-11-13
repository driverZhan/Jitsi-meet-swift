import JitsiCore
import SwiftUI

/// Appearance of `MeetingTimerText`.
public struct MeetingTimerStyle {
    public enum Mode {
        /// Time since the meeting started.
        case elapsed
        /// Time left before the limit.
        case remaining
        /// `elapsed / limit`, falling back to elapsed when no limit is known.
        case elapsedAndLimit
    }

    public var mode: Mode
    /// Remaining time at which the text turns amber, matching the reference client's
    /// five-minute warning.
    public var warningThreshold: TimeInterval
    /// Past the limit, show `+mm:ss` instead of clamping at zero.
    public var showsOverrun: Bool

    public init(
        mode: Mode = .elapsedAndLimit,
        warningThreshold: TimeInterval = 300,
        showsOverrun: Bool = true
    ) {
        self.mode = mode
        self.warningThreshold = warningThreshold
        self.showsOverrun = showsOverrun
    }
}

/// The meeting clock, refreshed once a second.
///
/// Reads `MeetingSession.meetingTiming`; until that exists it renders nothing, so it is safe
/// to place in a bar that shows before the join completes.
public struct MeetingTimerText: View {
    private let session: MeetingSession
    private let style: MeetingTimerStyle

    public init(session: MeetingSession, style: MeetingTimerStyle = MeetingTimerStyle()) {
        self.session = session
        self.style = style
    }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let timing = session.meetingTiming
            Text(caption(for: timing, at: context.date))
                .monospacedDigit()
                .foregroundStyle(color(for: timing, at: context.date))
                .accessibilityLabel(Text(accessibility(for: timing, at: context.date)))
        }
    }

    private func caption(for timing: MeetingTiming?, at date: Date) -> String {
        guard let timing else { return "" }
        let elapsed = clock(timing.elapsed(at: date))
        switch style.mode {
        case .elapsed:
            return overrunSuffix(timing, at: date, base: elapsed)
        case .remaining:
            guard let remaining = timing.remaining(at: date) else { return elapsed }
            return remaining >= 0 ? clock(remaining) : overrunSuffix(timing, at: date, base: "00:00")
        case .elapsedAndLimit:
            guard let limit = timing.timeLimit else {
                return overrunSuffix(timing, at: date, base: elapsed)
            }
            return "\(overrunSuffix(timing, at: date, base: elapsed)) / \(clock(limit))"
        }
    }

    private func overrunSuffix(_ timing: MeetingTiming, at date: Date, base: String) -> String {
        guard style.showsOverrun,
              let remaining = timing.remaining(at: date),
              remaining < 0
        else { return base }
        return "\(base) +\(clock(-remaining))"
    }

    private func color(for timing: MeetingTiming?, at date: Date) -> Color {
        guard let timing, let remaining = timing.remaining(at: date) else { return .primary }
        if remaining <= 0 { return .red }
        if remaining <= style.warningThreshold { return .orange }
        return .primary
    }

    private func accessibility(for timing: MeetingTiming?, at date: Date) -> String {
        guard let timing else { return "" }
        let elapsed = Int(timing.elapsed(at: date))
        switch timing.remaining(at: date) {
        case .some(let remaining) where remaining < 0:
            return "Meeting running \(elapsed) seconds, \(Int(-remaining)) over the limit"
        case .some(let remaining):
            return "Meeting running \(elapsed) seconds, \(Int(remaining)) left"
        case .none:
            return "Meeting running \(elapsed) seconds"
        }
    }

    private func clock(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }
}
