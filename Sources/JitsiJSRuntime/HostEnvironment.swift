import Foundation
import JitsiCore
#if canImport(UIKit)
import UIKit
#endif

/// Device facts the JS `navigator`/`screen`/`location` shims report.
public struct HostEnvironment: Sendable {
    public var userAgent: String
    public var platform: String
    public var hostname: String
    public var origin: String
    public var language: String
    public var screenWidth: Int
    public var screenHeight: Int
    public var scale: Double
    public var cpuCount: Int
    public var online: Bool
    public var visible: Bool
    public var mediaBackendReady: Bool
    public var reactNativeVersion: String

    public static func current(host: String, backendReady: Bool) -> HostEnvironment {
        #if canImport(UIKit)
        let screen = UIScreen.main
        let bounds = screen.bounds
        let scale = Double(screen.scale)
        #else
        let bounds = CGRectZeroLike
        let scale = 2.0
        #endif

        let version = ProcessInfo.processInfo.operatingSystemVersion
        // No "ReactNative/x.y.z" token here on purpose: lib-jitsi-meet's BrowserDetection
        // prefers the UA token it finds over `navigator.product` and then compares it against
        // the literal 'react-native', so this token would make isReactNative() false and send
        // the client down the plain-browser code paths.
        return HostEnvironment(
            userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS \(version.majorVersion)_\(version.minorVersion)_\(version.patchVersion) like Mac OS X) "
                + "AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 JitsiNative/1.0",
            platform: "iOS",
            hostname: host,
            origin: "https://" + host,
            language: preferredLanguageCode(),
            screenWidth: Int(bounds.width),
            screenHeight: Int(bounds.height),
            scale: scale,
            cpuCount: ProcessInfo.processInfo.activeProcessorCount,
            online: true,
            visible: true,
            mediaBackendReady: backendReady,
            reactNativeVersion: "0.77.0"
        )
    }

    private static func preferredLanguageCode() -> String {
        if #available(iOS 16.0, *) {
            return Locale.current.language.languageCode?.identifier ?? "en"
        }
        return Locale.current.languageCode ?? "en"
    }
}

#if !canImport(UIKit)
private let CGRectZeroLike = CGRect(x: 0, y: 0, width: 390, height: 844)
#endif
