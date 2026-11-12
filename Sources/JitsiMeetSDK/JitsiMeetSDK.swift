import Foundation
// Re-exported so an integrator who links the single packaged framework only needs
// `import JitsiMeetSDK`. The packaged xcframework keeps every submodule's `.swiftmodule`
// inside the same `Modules` directory, which is exactly what the loader consults when
// resolving these re-exports.
@_exported import JitsiCall
@_exported import JitsiCore
@_exported import JitsiJSRuntime
@_exported import JitsiMedia
@_exported import JitsiUI

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

    /// Single entry from "app launched" to the prejoin screen: installs the runtime when it
    /// is not running yet, connects and opens local capture, then returns a session parked
    /// at `.ready`. Call `join()` on it (or present a `MeetingContainer`) to enter the room.
    ///
    /// The runtime is bound to one XMPP host at install time, so a request aimed at another
    /// deployment is rejected instead of silently talking to the installed host.
    public static func startMeeting(
        _ request: MeetingRequest,
        config: SDKConfig = SDKConfig()
    ) async throws -> MeetingSession {
        let engine: MeetingEngine
        if let existing = installed {
            engine = existing
        } else {
            engine = try await bootstrap(
                config: config,
                conferenceHost: request.connection.serviceUrl
            )
        }
        try verifyHost(of: engine, matches: request.connection)
        let session = MeetingSession()
        try await session.start(request)
        return session
    }

    private static func verifyHost(of engine: MeetingEngine, matches connection: ConnectionOptions) throws {
        guard let installedHost = (engine as? JSMeetingEngine)?.hostName else { return }
        let expected = ServerAddress(connection.serviceUrl).host
        guard ServerAddress(installedHost).host.lowercased() == expected.lowercased() else {
            throw JitsiError.invalidArgument(
                "the engine is installed for \(installedHost), not \(expected); "
                + "call shutdown() before switching deployments"
            )
        }
    }

    /// Convenience so an app can present the whole join flow without writing the store.
    public static func meetingContainer(
        request: MeetingRequest,
        layout: MeetingLayout = .standard,
        autoJoin: Bool = false,
        onEnded: @escaping () -> Void = {}
    ) -> MeetingContainer {
        MeetingContainer(request: request, layout: layout, autoJoin: autoJoin, onEnded: onEnded)
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
