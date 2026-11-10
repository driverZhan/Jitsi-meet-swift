// swift-tools-version: 6.0
import PackageDescription

// Swift 5 language mode: JSContext is not Sendable and is confined to a serial queue.
// Migrating the runtime layer to strict concurrency is tracked as a follow-up.
let settings: [SwiftSetting] = [.swiftLanguageMode(.v5)]

// Every public module is also a product, so an integrator can consume the sources with
// SwiftPM, and `Scripts/build-xcframework.sh` collapses them into one distributable
// framework. Static (not `.dynamic`) on purpose: an integrator then embeds exactly one
// binary — WebRTC — and the SDK's own archive is linked into the app, which keeps device
// signing to a single step.
let sdkProducts: [Product] = [
    "JitsiCore", "JitsiMedia", "JitsiJSRuntime", "JitsiUI", "JitsiCall", "JitsiMeetSDK",
    "JitsiMeetExample", "JitsiObjC"
].map { .library(name: $0, type: .static, targets: [$0]) }

let package = Package(
    name: "JitsiMeetSDK",
    defaultLocalization: "en",
    platforms: [.iOS("15.0")],
    products: sdkProducts,
    targets: [
        // libwebrtc, vendored so the package is self-contained: integrating apps add no
        // separate WebRTC dependency. `Frameworks/WebRTC-LICENSE.txt` records the exact Jitsi
        // build and how it was trimmed to the two iOS slices.
        .binaryTarget(name: "WebRTC", path: "Frameworks/WebRTC.xcframework"),

        // Public API + domain types. Depends on nothing.
        .target(name: "JitsiCore", swiftSettings: settings),

        // iOS capture, audio session, rendering, and the libwebrtc backend.
        .target(name: "JitsiMedia", dependencies: ["JitsiCore", "WebRTC"], swiftSettings: settings),

        // lib-jitsi-meet running on JavaScriptCore + the native shims it needs.
        .target(
            name: "JitsiJSRuntime",
            dependencies: ["JitsiCore", "JitsiMedia"],
            resources: [.copy("Resources/js")],
            swiftSettings: settings
        ),

        // Native SwiftUI meeting UI, rendered from media frames only.
        .target(name: "JitsiUI", dependencies: ["JitsiCore", "JitsiMedia"], swiftSettings: settings),

        // Incoming-call presentation: notification + in-app overlay, no system call UI.
        .target(name: "JitsiCall", dependencies: ["JitsiCore"], swiftSettings: settings),

        // Umbrella: wires the JS engine + media backend into JitsiCore.
        .target(
            name: "JitsiMeetSDK",
            dependencies: ["JitsiCore", "JitsiJSRuntime", "JitsiMedia", "JitsiUI", "JitsiCall"],
            swiftSettings: settings
        ),

        // Custom-UI demo: the screen an integrator would write, using only public API.
        .target(
            name: "JitsiMeetExample",
            dependencies: ["JitsiCore", "JitsiUI", "JitsiMeetSDK"],
            swiftSettings: settings
        ),

        // Objective-C façade over the umbrella. `@objc` classes in this target are what the
        // packaged framework exposes through its generated `JitsiMeetSDK-Swift.h`.
        .target(
            name: "JitsiObjC",
            dependencies: ["JitsiCore", "JitsiMeetSDK"],
            swiftSettings: settings
        ),

        // The demo host app: a SwiftUI scene that presents the custom screen. Not a product;
        // `Scripts/make-demo-app.sh` assembles it into an .app bundle and installs it on a
        // simulator, because a bare SwiftPM executable has no bundle and iOS needs one.
        .executableTarget(
            name: "JitsiMeetDemoApp",
            dependencies: ["JitsiMeetSDK", "JitsiMeetExample"],
            swiftSettings: settings
        ),

        .testTarget(
            name: "JitsiCoreTests",
            dependencies: ["JitsiCore", "JitsiJSRuntime", "JitsiMedia", "JitsiCall", "JitsiMeetExample"],
            swiftSettings: settings
        )
    ]
)

// `WebRTCBackend.swift` is guarded by `#if canImport(WebRTC)`, which is now always true here
// because the xcframework is vendored. Delete `Frameworks/WebRTC.xcframework` and the
// `.binaryTarget` line to shed ~34 MB — `MediaBackendFactory` then falls back to
// `UnavailableMediaBackend`, which fails loudly instead of pretending to work.
