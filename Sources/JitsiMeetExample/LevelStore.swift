import JitsiCore
import SwiftUI

/// The part of the demo that is a fully custom state machine: everything `MeetingSession`
/// does not surface, reduced straight from `JitsiMeet.shared.events`.
///
/// One hub broadcast reaches every subscriber, so this store and the screen's
/// `MeetingSession` each hold one subscription and must both release it.
@MainActor
public final class LevelStore: ObservableObject {
    @Published public private(set) var levels: [ParticipantID: Double] = [:]
    @Published public private(set) var dominantSpeaker: ParticipantID?
    @Published public private(set) var mutedParticipants: Set<String> = []
    @Published public private(set) var lastBreakoutRooms: BreakoutRoomsState?
    @Published public private(set) var log: [String] = []

    private var subscription: Subscription?

    public init() {}

    deinit {
        subscription?.unsubscribe()
    }

    public func observe() {
        stopObserving()
        subscription = JitsiMeet.shared.events.subscribe { [weak self] event in
            Task { @MainActor in self?.apply(event) }
        }
    }

    public func stopObserving() {
        subscription?.unsubscribe()
        subscription = nil
    }

    public static func key(_ participantID: ParticipantID, _ mediaType: MediaType) -> String {
        "\(participantID)/\(mediaType.rawValue)"
    }

    /// 0...1 for a speaking ring. Anything above 1 is read as the lib's 0-100 display scale,
    /// so a change of the upstream mapping degrades the ring instead of pinning it open.
    public func level(for participantID: ParticipantID) -> Double {
        let raw = levels[participantID] ?? 0
        let scaled = raw > 1 ? raw / 100 : raw
        return Swift.min(Swift.max(scaled, 0), 1)
    }

    public func isSpeaking(_ participantID: ParticipantID) -> Bool {
        level(for: participantID) > 0.05
    }

    public func isMuted(_ participantID: ParticipantID, _ mediaType: MediaType) -> Bool {
        mutedParticipants.contains(Self.key(participantID, mediaType))
    }

    private func apply(_ event: MeetingEvent) {
        switch event {
        case .audioLevels(let latest):
            levels = latest
        case .dominantSpeakerChanged(let participantID):
            dominantSpeaker = participantID
        case .participantMuted(let participantID, let mediaType, let muted):
            let key = Self.key(participantID, mediaType)
            if muted { mutedParticipants.insert(key) } else { mutedParticipants.remove(key) }
        case .participantLeft(let snapshot):
            levels[snapshot.id] = nil
            mutedParticipants = mutedParticipants.filter { !$0.hasPrefix("\(snapshot.id)/") }
            if dominantSpeaker == snapshot.id { dominantSpeaker = nil }
        case .breakoutRoomsUpdated(let state):
            lastBreakoutRooms = state
        default:
            break
        }
        record(event)
    }

    private func record(_ event: MeetingEvent) {
        let detail: String
        switch event {
        case .connectionStatus(let status, let message):
            detail = status.rawValue + (message.map { " (\($0))" } ?? "")
        case .raw(let name, let payload):
            detail = name + " \(payload)"
        case .audioLevels(let levels):
            detail = levels.count == 0 ? "silent" : "\(levels.count) reporting"
        default:
            detail = ""
        }
        log.append([Self.caseName(of: event), detail].filter { !$0.isEmpty }.joined(separator: ": "))
        if log.count > 80 {
            log.removeFirst(log.count - 80)
        }
    }

    private static func caseName(of event: MeetingEvent) -> String {
        let described = String(describing: event)
        guard let paren = described.firstIndex(of: "(") else { return described }
        return String(described[described.startIndex..<paren])
    }
}
