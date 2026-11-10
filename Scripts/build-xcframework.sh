#!/usr/bin/env bash
# Package the SDK as ONE distributable xcframework.
#
# The seven Swift modules are compiled together into a single `JitsiMeetSDK` module, so an
# integrator links one static framework and imports one module. WebRTC is deliberately not
# embedded: the host app provides it as an SPM binary target or a CocoaPods pod (see the
# generated INTEGRATION.txt for the exact requirements).
#
#   ./Scripts/build-xcframework.sh
#   DIST=/tmp/sdk ./Scripts/build-xcframework.sh
set -euo pipefail
cd "$(dirname "$0")/.."

MODULE=JitsiMeetSDK
SOURCE_MODULES=(JitsiCore JitsiMedia JitsiJSRuntime JitsiUI JitsiCall JitsiMeetSDK JitsiObjC JitsiMeetExample)
RESOURCE_TARGET=JitsiMeetSDK
DIST="${DIST:-dist}"
STAGE=.build/single-xcframework-stage
UNIFIED=.build/unified-package
VERSION="${DEMO_VERSION:-1.0}"

rm -rf "$STAGE" "$DIST" "$UNIFIED"
mkdir -p "$STAGE" "$DIST" "$UNIFIED/Sources/$MODULE" "$UNIFIED/Frameworks"

# ---------------------------------------------------------------------------
# One module: flatten every public source file into a single target and drop the
# cross-module imports (they no longer exist inside the merged module). `@_exported` lines
# from the umbrella go too.
# ---------------------------------------------------------------------------
for module in "${SOURCE_MODULES[@]}"; do
  find "Sources/$module" -name '*.swift' -print0 | while IFS= read -r -d '' file; do
    cp "$file" "$UNIFIED/Sources/$MODULE/$(basename "$file")"
  done
done

DUPLICATES=$(find "$UNIFIED/Sources/$MODULE" -maxdepth 1 -name '*.swift' -exec basename {} \; | sort | uniq -d)
if [ -n "$DUPLICATES" ]; then
  echo "error: two source files share a name; flattening would drop one:" >&2
  echo "$DUPLICATES" >&2
  exit 1
fi

find "$UNIFIED/Sources/$MODULE" -name '*.swift' -exec sed -i '' -E \
  '/^(@_exported )?import Jitsi(Core|Media|JSRuntime|UI|Call|MeetSDK|ObjC)$/d' {} +

cp -R Sources/JitsiJSRuntime/Resources "$UNIFIED/Sources/$MODULE/Resources"
# WebRTC is only needed to compile the backend here; it is not part of the deliverable.
cp -R Frameworks/WebRTC.xcframework "$UNIFIED/Frameworks/"

cat >"$UNIFIED/Package.swift" <<'SWIFT'
// swift-tools-version: 6.0
import PackageDescription

let settings: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "JitsiMeetSDK",
    platforms: [.iOS("15.0")],
    products: [.library(name: "JitsiMeetSDK", type: .static, targets: ["JitsiMeetSDK"])],
    targets: [
        .binaryTarget(name: "WebRTC", path: "Frameworks/WebRTC.xcframework"),
        .target(
            name: "JitsiMeetSDK",
            dependencies: ["WebRTC"],
            resources: [.copy("Resources/js")],
            swiftSettings: settings
        )
    ]
)
SWIFT

# ---------------------------------------------------------------------------
# Build one platform slice, including the ObjC compatibility header.
# ---------------------------------------------------------------------------
build_platform() { # $1 = slice id, $2 = swift triple, $3 = sdk, $4 = module suffix, $5 = plist platform
  local slice="$1" triple="$2" sdk="$3" suffix="$4" plist_platform="$5"
  local out="$STAGE/$slice"
  mkdir -p "$out"

  local callkit=()
  if [ "${JITSI_ENABLE_CALLKIT:-}" = "1" ]; then
    callkit=(-Xswiftc -DJITSI_ENABLE_CALLKIT)
  fi

  swift build --package-path "$UNIFIED" --configuration release \
    --triple "$triple" --sdk "$(xcrun --sdk "$sdk" --show-sdk-path)" \
    ${callkit[@]+"${callkit[@]}"} \
    -Xswiftc -emit-objc-header \
    -Xswiftc -emit-objc-header-path -Xswiftc "$out/$MODULE-Swift.h"

  # Depending on the build system SwiftPM may move (or re-point) the ObjC header into its
  # intermediates directory instead of honouring -emit-objc-header-path.
  if [ ! -f "$out/$MODULE-Swift.h" ]; then
    local generated
    generated=$(find "$UNIFIED/.build" -name "$MODULE-Swift.h" -path "*GeneratedModuleMaps-$sdk*" -print -quit)
    if [ -z "$generated" ]; then
      generated=$(find "$UNIFIED/.build" -name "$MODULE-Swift.h" -print -quit)
    fi
    [ -n "$generated" ] && cp "$generated" "$out/$MODULE-Swift.h"
  fi

  local products
  products=$(cd "$UNIFIED/.build/release" && pwd)

  local fw="$out/$MODULE.framework"
  mkdir -p "$fw/Modules/$MODULE.swiftmodule" "$fw/Headers"
  cp "$products/lib$MODULE.a" "$fw/$MODULE"
  cp "$products/$MODULE.swiftmodule/$suffix.swiftmodule" "$fw/Modules/$MODULE.swiftmodule/"
  cp "$products/$MODULE.swiftmodule/$suffix.abi.json" "$fw/Modules/$MODULE.swiftmodule/"
  cp "$products/$MODULE.swiftmodule/$suffix.swiftdoc" "$fw/Modules/$MODULE.swiftmodule/"

  if [ ! -f "$out/$MODULE-Swift.h" ]; then
    echo "error: $MODULE-Swift.h was not generated for $slice" >&2
    exit 1
  fi
  cp "$out/$MODULE-Swift.h" "$fw/Headers/"
  cat >"$fw/Headers/$MODULE.h" <<HEADER
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "$MODULE-Swift.h"
HEADER
  cat >"$fw/Modules/module.modulemap" <<MODULEMAP
framework module $MODULE {
  umbrella header "$MODULE.h"
  export *
  module * { export * }
}
MODULEMAP

  cat >"$fw/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$MODULE</string>
  <key>CFBundleIdentifier</key><string>org.jitsi.swift.$MODULE</string>
  <key>CFBundleName</key><string>$MODULE</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleSupportedPlatforms</key><array><string>$plist_platform</string></array>
  <key>MinimumOSVersion</key><string>15.0</string>
</dict>
</plist>
PLIST

  # A static framework cannot carry resources that reach the app by itself. Ship the JS
  # bundle beside the framework; the app adds it to Copy Bundle Resources.
  local bundle="$products/${RESOURCE_TARGET}_${RESOURCE_TARGET}.bundle"
  if [ -d "$bundle" ]; then
    cp -R "$bundle" "$out/"
  fi
}

build_platform ios-arm64 arm64-apple-ios15.0 iphoneos arm64-apple-ios iPhoneOS
build_platform ios-arm64-simulator arm64-apple-ios15.0-simulator iphonesimulator arm64-apple-ios-simulator iPhoneSimulator

# ---------------------------------------------------------------------------
# Single xcframework container.
# ---------------------------------------------------------------------------
OUT="$DIST/$MODULE.xcframework"
mkdir -p "$OUT/ios-arm64" "$OUT/ios-arm64-simulator"
cp -R "$STAGE/ios-arm64/$MODULE.framework" "$OUT/ios-arm64/"
cp -R "$STAGE/ios-arm64-simulator/$MODULE.framework" "$OUT/ios-arm64-simulator/"
cat >"$OUT/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundlePackageType</key><string>XFWK</string>
  <key>XCFrameworkFormatVersion</key><string>1.0</string>
  <key>AvailableLibraries</key>
  <array>
    <dict>
      <key>BinaryPath</key><string>$MODULE.framework/$MODULE</string>
      <key>LibraryIdentifier</key><string>ios-arm64</string>
      <key>LibraryPath</key><string>$MODULE.framework</string>
      <key>SupportedArchitectures</key><array><string>arm64</string></array>
      <key>SupportedPlatform</key><string>ios</string>
    </dict>
    <dict>
      <key>BinaryPath</key><string>$MODULE.framework/$MODULE</string>
      <key>LibraryIdentifier</key><string>ios-arm64-simulator</string>
      <key>LibraryPath</key><string>$MODULE.framework</string>
      <key>SupportedArchitectures</key><array><string>arm64</string></array>
      <key>SupportedPlatform</key><string>ios</string>
      <key>SupportedPlatformVariant</key><string>simulator</string>
    </dict>
  </array>
</dict>
</plist>
PLIST

# One copy of the JS bundle for the app's Resources; both slices carry the same files.
BUNDLE="$STAGE/ios-arm64/${RESOURCE_TARGET}_${RESOURCE_TARGET}.bundle"
if [ -d "$BUNDLE" ]; then
  cp -R "$BUNDLE" "$DIST/"
fi
cp Frameworks/WebRTC-LICENSE.txt "$DIST/" 2>/dev/null || true

cat >"$DIST/INTEGRATION.txt" <<'TXT'
JitsiMeetSDK — single static xcframework
========================================

Contents
--------
  JitsiMeetSDK.xcframework        one static framework (device + arm64 simulator)
  JitsiMeetSDK_JitsiMeetSDK.bundle  JS runtime resources; add to Copy Bundle Resources
  WebRTC-LICENSE.txt              provenance of the WebRTC build this was compiled against

WebRTC is NOT inside the framework. Link the same build described in WebRTC-LICENSE.txt
through an SPM binary target or a CocoaPods pod that provides `WebRTC.framework`.
At minimum the app must link: WebRTC, AVFoundation, CoreMedia, CoreVideo, Accelerate,
CoreImage, JavaScriptCore, ReplayKit, SwiftUI, UIKit.

Swift
-----
  import JitsiMeetSDK                 // re-exports every SDK module

  The module ships as a binary .swiftmodule (no .swiftinterface), so build the host app with
  the same Xcode/Swift version that produced this framework, or rebuild from the source package.

Objective-C
-----------
  #import <JitsiMeetSDK/JitsiMeetSDK.h>
  // JitsiSDK.shared, settable JitsiSDKDelegate, completion blocks on the main queue.

Build settings
--------------
  * Add the xcframework under "Frameworks, Libraries and Embedded Content" (Do Not Embed;
    it is static). Embedding the WebRTC framework remains the single signed binary.
  * Add JitsiMeetSDK_JitsiMeetSDK.bundle to the app target's Copy Bundle Resources.
  * Set an App Group on the app and on its Broadcast Upload Extension, then assign the same
    id to ScreenShareConfiguration.appGroupIdentifier / the extension template. ReplayKit
    needs the extension; without it the screen-share track stays empty.
TXT

echo
echo "packaged into $DIST/"
printf '  %-30s %s\n' "$MODULE.xcframework" "$(du -sh "$OUT" | cut -f1)"
[ -d "$DIST/${RESOURCE_TARGET}_${RESOURCE_TARGET}.bundle" ] && \
  printf '  %-30s %s\n' "${RESOURCE_TARGET}_${RESOURCE_TARGET}.bundle" "$(du -sh "$DIST/${RESOURCE_TARGET}_${RESOURCE_TARGET}.bundle" | cut -f1)"
echo
echo "WebRTC is intentionally excluded; see $DIST/INTEGRATION.txt."
