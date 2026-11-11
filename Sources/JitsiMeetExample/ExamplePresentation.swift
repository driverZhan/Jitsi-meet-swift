import JitsiCore
import JitsiMeetSDK
import SwiftUI
import UIKit

/// The demo's host-side glue: an app would normally own this configuration, and a storyboarding
/// or Objective-C host needs a view controller rather than a SwiftUI tree.
@MainActor
public enum JitsiMeetDemo {
    // Default arguments are evaluated outside the actor, so these stay nonisolated.
    // Accepts a bare host too; `ServerAddress` strips the scheme and keeps the port.
    // The active demo deployment is the official public one: hosts.domain = meet.jit.si,
    // hosts.muc = conference.meet.jit.si and hosts.anonymousdomain = guest.meet.jit.si
    // (see https://meet.jit.si/config.js). A self-hosted deployment stays reachable by
    // passing its host together with domain/muc explicitly.
    nonisolated public static var defaultHost: String { "https://meet.jit.si" }
    nonisolated public static var defaultDomain: String { "meet.jit.si" }
    nonisolated public static var defaultMuc: String { "conference.meet.jit.si" }
    // Anonymous XMPP auth for meet.jit.si; empty for deployments that authenticate as `domain`.
    nonisolated public static var defaultAnonymousDomain: String { "guest.meet.jit.si" }
    // Prefer WebSocket: some deployments balance /http-bind across shards without sticky
    // sessions, so a BOSH stream intermittently ends with `item-not-found` mid-handshake.
    // /xmpp-websocket pins the stream to one proxy connection and upgrades cleanly.
    nonisolated public static var defaultTransport: ServerAddress.Transport { .websocket }
    // An XMPP room JID's node part must be lowercase, so a mixed-case name fails to join.
    nonisolated public static var defaultRoom: String { "teambind" }

    public static func connection(
        host: String = JitsiMeetDemo.defaultHost,
        transport: ServerAddress.Transport = JitsiMeetDemo.defaultTransport,
        domain: String? = nil,
        muc: String? = nil,
        anonymousDomain: String? = nil
    ) -> ConnectionOptions {
        // The active deployment's domains are pinned only for its exact host (meet.jit.si
        // derives the same values anyway); any other host derives its own, and self-hosted
        // deployments whose XMPP domain differs pass domain/muc explicitly.
        let usingDefaultHost = ServerAddress(host).host.lowercased()
            == ServerAddress(JitsiMeetDemo.defaultHost).host.lowercased()
        let resolvedDomain = nonEmpty(domain)
            ?? (usingDefaultHost ? JitsiMeetDemo.defaultDomain : ServerAddress(host).domain)
        let resolvedMuc = nonEmpty(muc)
            ?? (usingDefaultHost ? JitsiMeetDemo.defaultMuc : "conference.\(resolvedDomain)")
        let server = ServerAddress(host, transport: transport, domain: resolvedDomain, muc: resolvedMuc)
        let anonymous = anonymousDomain ?? JitsiMeetDemo.anonymousDomain(forHost: host)
        return ConnectionOptions(
            serviceUrl: server.serviceUrl,
            hosts: ConnectionOptions.Hosts(
                domain: server.domain,
                muc: server.muc,
                anonymousdomain: nonEmpty(anonymous)
            )
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    /// meet.jit.si authenticates anonymous users against `guest.meet.jit.si`; a self-hosted
    /// deployment without `hosts.anonymousdomain` must not inherit that domain. Callers can
    /// pass `anonymousDomain` explicitly to override either way.
    private static func anonymousDomain(forHost host: String) -> String? {
        // Match the parsed XMPP domain exactly: a substring check would also enable the
        // guest domain for lookalikes such as `meet.jit.si.example.org`.
        ServerAddress(host).domain.lowercased() == "meet.jit.si" ? JitsiMeetDemo.defaultAnonymousDomain : nil
    }

    public static func conference(
        room: String = JitsiMeetDemo.defaultRoom,
        displayName: String = "Swift Guest",
        email: String? = nil,
        avatarURL: String? = nil,
        password: String? = nil
    ) -> ConferenceOptions {
        ConferenceOptions(
            name: room,
            userInfo: UserInfo(displayName: displayName, email: email, avatarURL: avatarURL),
            password: password?.isEmpty == false ? password : nil
        )
    }

    /// Install the JS runtime + libwebrtc backend. Call once from the app delegate or a
    /// `Task` at launch; presenting the screen without it lands the error on the banner.
    @discardableResult
    public static func bootstrap(
        host: String = JitsiMeetDemo.defaultHost,
        region: SDKConfig.Region = .international,
        debugSignaling: Bool = false
    ) async throws -> MeetingEngine {
        // The demo project ships the broadcast upload extension as the "JitsiBroadcastExtension"
        // target; both bundles declare the same App Group in their entitlements.
        ScreenShareConfiguration.appGroupIdentifier = "group.com.jitsi.meetsdk"
        ScreenShareConfiguration.extensionBundleIdentifier = "org.jitsi.swift.demo.broadcast"
        return try await JitsiMeetSDK.bootstrap(
            config: SDKConfig(region: region, debugSignaling: debugSignaling),
            conferenceHost: host
        )
    }

    public static func screen(
        host: String = JitsiMeetDemo.defaultHost,
        transport: ServerAddress.Transport = JitsiMeetDemo.defaultTransport,
        domain: String? = nil,
        muc: String? = nil,
        room: String = JitsiMeetDemo.defaultRoom,
        displayName: String = "Swift Guest",
        email: String? = nil,
        avatarURL: String? = nil,
        password: String? = nil,
        onEnded: @escaping () -> Void = {}
    ) -> DemoMeetingScreen {
        DemoMeetingScreen(
            connection: connection(host: host, transport: transport, domain: domain, muc: muc),
            conference: conference(
                room: room,
                displayName: displayName,
                email: email,
                avatarURL: avatarURL,
                password: password
            ),
            onEnded: onEnded
        )
    }

    public static func viewController(
        host: String = JitsiMeetDemo.defaultHost,
        transport: ServerAddress.Transport = JitsiMeetDemo.defaultTransport,
        domain: String? = nil,
        muc: String? = nil,
        room: String = JitsiMeetDemo.defaultRoom,
        displayName: String = "Swift Guest",
        email: String? = nil,
        avatarURL: String? = nil,
        password: String? = nil,
        onEnded: @escaping () -> Void = {}
    ) -> UIViewController {
        UIHostingController(rootView: screen(
            host: host,
            transport: transport,
            domain: domain,
            muc: muc,
            room: room,
            displayName: displayName,
            email: email,
            avatarURL: avatarURL,
            password: password,
            onEnded: onEnded
        ))
    }

    /// What an incoming call would look like for this region in this build, for a settings row.
    public static func callPresentationSummary(for region: SDKConfig.Region) -> String {
        JitsiMeetSDK.callPresentation(for: region)
    }
}
