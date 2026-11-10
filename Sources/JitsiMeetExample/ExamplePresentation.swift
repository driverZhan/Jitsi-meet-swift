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
    nonisolated public static var defaultHost: String { "https://tmeeting.maesgroup.com:8443" }
    // docker-jitsi-meet terminates the transport on the public host but Prosody identifies
    // itself as `meet.jitsi`, so the XMPP and MUC domains are separate settings.
    nonisolated public static var defaultDomain: String { "meet.jitsi" }
    nonisolated public static var defaultMuc: String { "muc.meet.jitsi" }
    // The deployment's WebSocket endpoint answers HTTP 501; BOSH is the working transport.
    nonisolated public static var defaultTransport: ServerAddress.Transport { .bosh }
    // An XMPP room JID's node part must be lowercase, so a mixed-case name fails to join.
    nonisolated public static var defaultRoom: String { "jitsi-swift-demo" }

    public static func connection(
        host: String = JitsiMeetDemo.defaultHost,
        transport: ServerAddress.Transport = JitsiMeetDemo.defaultTransport,
        domain: String = JitsiMeetDemo.defaultDomain,
        muc: String = JitsiMeetDemo.defaultMuc
    ) -> ConnectionOptions {
        let server = ServerAddress(host, transport: transport, domain: domain, muc: muc)
        return ConnectionOptions(
            serviceUrl: server.serviceUrl,
            hosts: ConnectionOptions.Hosts(domain: server.domain, muc: server.muc)
        )
    }

    public static func conference(
        room: String = JitsiMeetDemo.defaultRoom,
        displayName: String = "Swift Guest",
        email: String? = nil,
        avatarURL: String? = nil
    ) -> ConferenceOptions {
        ConferenceOptions(
            name: room,
            userInfo: UserInfo(displayName: displayName, email: email, avatarURL: avatarURL)
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
        domain: String = JitsiMeetDemo.defaultDomain,
        muc: String = JitsiMeetDemo.defaultMuc,
        room: String = JitsiMeetDemo.defaultRoom,
        displayName: String = "Swift Guest",
        email: String? = nil,
        avatarURL: String? = nil,
        onEnded: @escaping () -> Void = {}
    ) -> DemoMeetingScreen {
        DemoMeetingScreen(
            connection: connection(host: host, transport: transport, domain: domain, muc: muc),
            conference: conference(
                room: room,
                displayName: displayName,
                email: email,
                avatarURL: avatarURL
            ),
            onEnded: onEnded
        )
    }

    public static func viewController(
        host: String = JitsiMeetDemo.defaultHost,
        transport: ServerAddress.Transport = JitsiMeetDemo.defaultTransport,
        domain: String = JitsiMeetDemo.defaultDomain,
        muc: String = JitsiMeetDemo.defaultMuc,
        room: String = JitsiMeetDemo.defaultRoom,
        displayName: String = "Swift Guest",
        email: String? = nil,
        avatarURL: String? = nil,
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
            onEnded: onEnded
        ))
    }

    /// What an incoming call would look like for this region in this build, for a settings row.
    public static func callPresentationSummary(for region: SDKConfig.Region) -> String {
        JitsiMeetSDK.callPresentation(for: region)
    }
}
