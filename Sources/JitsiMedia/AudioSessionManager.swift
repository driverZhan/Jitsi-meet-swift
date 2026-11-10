import AVFoundation
import Foundation

/// Owns the `AVAudioSession`. This is the main thing native gives you over the browser:
/// route control, interruptions, and background continuity without CallKit.
@MainActor
public final class AudioSessionManager {
    public enum Route: String {
        case builtInReceiver
        case builtInSpeaker
        case headphones
        case bluetooth
        case carPlay
    }

    public private(set) var isActive = false
    public private(set) var currentRoute: Route = .builtInReceiver

    /// Fires when the system takes the session away (call, Siri) or the route changes.
    public var onInterruption: ((Bool) -> Void)?
    public var onRouteChange: ((Route) -> Void)?

    private let session = AVAudioSession.sharedInstance()

    public init() {}

    public func beginConference(preferSpeaker: Bool = false) throws {
        try applyCategory(preferSpeaker: preferSpeaker)
        try session.setPreferredSampleRate(48_000)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        isActive = true
        refreshRoute()
    }

    public func endConference() throws {
        guard isActive else { return }
        try session.setActive(false, options: .notifyOthersOnDeactivation)
        isActive = false
    }

    /// Call after an interruption ends, or when the user switches to the speaker.
    public func preferSpeaker(_ speaker: Bool) throws {
        try applyCategory(preferSpeaker: speaker)
        refreshRoute()
    }

    private func applyCategory(preferSpeaker: Bool) throws {
        // `.mixWithOthers` must stay out: with the voice-processing I/O unit it keeps the
        // app from taking exclusive input and the speaker route, and the result is a live
        // call where neither side hears anything.
        var options: AVAudioSession.CategoryOptions = [.allowBluetoothHFP]
        if preferSpeaker { options.insert(.defaultToSpeaker) }
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: options)
    }

    public func observeSystemEvents() {
        let center = NotificationCenter.default
        center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            let began = type == .began
            Task { @MainActor [weak self] in self?.onInterruption?(began) }
        }
        center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshRoute()
                guard let self else { return }
                self.onRouteChange?(self.currentRoute)
            }
        }
    }

    private func refreshRoute() {
        guard let output = session.currentRoute.outputs.first else { return }
        switch output.portType {
        case .builtInReceiver: currentRoute = .builtInReceiver
        case .builtInSpeaker: currentRoute = .builtInSpeaker
        case .headphones: currentRoute = .headphones
        case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP: currentRoute = .bluetooth
        case .carAudio: currentRoute = .carPlay
        default: currentRoute = .headphones
        }
    }
}
