import AVFoundation
import Foundation
import JitsiCore

/// Owns the `AVAudioSession`. This is the main thing native gives you over the browser:
/// route control, interruptions, and background continuity without a system call UI.
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
    /// Fires when the active output moves, including to and from an external device. Not
    /// fired for the route the session starts on; the owner reads `currentRoute` then.
    public var onRouteChange: ((Route) -> Void)?

    private let session = AVAudioSession.sharedInstance()
    private var hasObservedSystemEvents = false

    public init() {
        observeSystemEvents()
    }

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

    /// Re-reads the hardware route without touching the category or activation. Used when an
    /// injected audio device (`VoiceProcessingAudioDevice`) owns `AVAudioSession`.
    public func refreshCurrentRoute() {
        if refreshRoute() {
            onRouteChange?(currentRoute)
        }
    }

    /// Call after an interruption ends, or when the user switches between the receiver and
    /// the speaker. With a headset, Bluetooth or CarPlay device connected the system keeps
    /// that route; only the built-in choice changes under it.
    public func preferSpeaker(_ speaker: Bool) throws {
        try applyCategory(preferSpeaker: speaker)
        if refreshRoute() {
            onRouteChange?(currentRoute)
        }
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
        guard !hasObservedSystemEvents else { return }
        hasObservedSystemEvents = true
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
                guard let self, self.refreshRoute() else { return }
                self.onRouteChange?(self.currentRoute)
            }
        }
    }

    /// Returns whether the route actually moved, so duplicate system notifications do not
    /// turn into duplicate app events.
    @discardableResult
    private func refreshRoute() -> Bool {
        let previous = currentRoute
        guard let output = session.currentRoute.outputs.first else { return false }
        switch output.portType {
        case .builtInReceiver: currentRoute = .builtInReceiver
        case .builtInSpeaker: currentRoute = .builtInSpeaker
        case .headphones: currentRoute = .headphones
        case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP: currentRoute = .bluetooth
        case .carAudio: currentRoute = .carPlay
        // USB, HDMI, AirPlay and screen-capture audio are external too: report them as
        // headphones so a receiver/speaker request cannot look like it took effect.
        default: currentRoute = .headphones
        }
        return currentRoute != previous
    }
}

extension AudioOutputRoute {
    /// Maps the platform port to the public route. The external cases are report-only; the
    /// audio session prefers them over the built-in choice while they are connected.
    public init(_ route: AudioSessionManager.Route) {
        switch route {
        case .builtInReceiver: self = .receiver
        case .builtInSpeaker: self = .speaker
        case .headphones: self = .headphones
        case .bluetooth: self = .bluetooth
        case .carPlay: self = .carPlay
        }
    }
}
