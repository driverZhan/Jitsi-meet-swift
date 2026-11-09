import Foundation
import JitsiCall
import JitsiCore
import JitsiJSRuntime
import JitsiMedia
import JitsiUI

/// Umbrella entry point.
///
/// One call wires the three layers together: the libwebrtc-backed `MediaBackend`, the
/// JavaScriptCore host that runs lib-jitsi-meet on top of it, and the fan-out that turns the
/// engine's event stream into `JitsiMeet.shared.events` for the API façades and the UI.
@MainActor
public enum JitsiMeetSDK {
    /// Retained here because `JitsiMeet.engine` is weak by design. Main-actor isolation of
    /// the whole type is what makes these two mutable globals safe.
    private static var installed: MeetingEngine?
    private static var pump: Task<Void, Never>?

    /// Install the engine. Safe to call more than once; the second call returns the engine
    /// that is already running.
    ///
    /// - Parameters:
    ///   - config: region, log level and codec capabilities.
    ///   - conferenceHost: XMPP conference host, e.g. `meet.example.org`. A full
    ///     `https://host:port` is accepted too; the shims only need the host part.
    ///   - backend: override for tests or for a native engine; defaults to the linked
    ///     libwebrtc backend, and to a loudly-failing placeholder when WebRTC is not linked.
    public static func bootstrap(
        config: SDKConfig = SDKConfig(),
        conferenceHost: String,
        backend: MediaBackend? = nil
    ) async throws -> MeetingEngine {
        if let existing = installed {
            JitsiMeet.shared.configure(config)
            await existing.setDebugSignaling(config.debugSignaling)
            return existing
        }

        JitsiMeet.shared.configure(config)
        let engine = JSMeetingEngine(
            backend: backend ?? MediaBackendFactory.makeDefault(capabilities: config.capabilities),
            hostName: ServerAddress(conferenceHost).host,
            logLevel: config.logLevel,
            debugSignaling: config.debugSignaling
        )
        JitsiMeet.shared.attach(engine)

        installed = engine

        let events = engine.events
        pump = Task {
            for await event in events {
                JitsiMeet.shared.events.publish(event)
            }
        }

        try await engine.install()
        return engine
    }

    /// Tear the runtime down. Also forgets the engine so a later `bootstrap` starts clean.
    public static func shutdown() async {
        let engine = installed
        installed = nil
        pump?.cancel()
        pump = nil

        guard let engine else { return }
        await engine.dispose()
    }

    public static var isInstalled: Bool { installed != nil }

    /// Toggle connection/signaling tracing on the installed engine without rebuilding the
    /// `JSContext`. Pass the same value to `bootstrap(config:)` when installing instead.
    public static func setDebugSignaling(_ enabled: Bool) async {
        await installed?.setDebugSignaling(enabled)
    }

    /// One-line summary of what an incoming call will look like in this build, for logs and
    /// for a settings screen.
    public static func callPresentation(for region: SDKConfig.Region) -> String {
        RegionPolicy.describe(for: region)
    }

    /// Convenience so an app can present a meeting without writing the store first.
    public static func meetingView(
        connection: ConnectionOptions,
        conference: ConferenceOptions,
        onEnded: @escaping () -> Void = {}
    ) -> MeetingView {
        MeetingView(connection: connection, conference: conference, onEnded: onEnded)
    }
}
