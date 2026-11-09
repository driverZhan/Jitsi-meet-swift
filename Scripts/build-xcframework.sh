#!/usr/bin/env bash
# Package every public module into its own .xcframework under dist/, so an integrator can drop
# the SDK into an Xcode project without SwiftPM. The archives are static on purpose: the only
# binary that then needs embedding (and therefore re-signing for a device) is WebRTC.
#
#   ./Scripts/build-xcframework.sh            # dist/ with 7 xcframeworks + WebRTC + the JS bundle
#   DIST=/tmp/sdk dist=... ./Scripts/build-xcframework.sh
set -euo pipefail
cd "$(dirname "$0")/.."

MODULES=(JitsiCore JitsiMedia JitsiJSRuntime JitsiUI JitsiCall JitsiMeetSDK JitsiMeetExample)
DIST="${DIST:-dist}"
STAGE=.build/xcframework-stage
VERSION="${DEMO_VERSION:-1.0}"

rm -rf "$STAGE" "$DIST"
mkdir -p "$STAGE" "$DIST"

# Builds one platform and copies the archives + swift interfaces into a staging directory,
# because `.build/debug` and `.build/release` are symlinks to whichever triple was built last.
build_platform() { # $1 = xcframework platform folder, $2 = swift triple, $3 = sdk name, $4 = arch suffix, $5 = CFBundleSupportedPlatforms
  local out="$STAGE/$1" triple="$2" sdk="$3" suffix="$4" plist_platform="$5"
  local products
  swift build --configuration release --triple "$triple" --sdk "$(xcrun --sdk "$sdk" --show-sdk-path)"
  products=$(cd .build/release && pwd)

  for module in "${MODULES[@]}"; do
    local fw="$out/$module.framework"
    mkdir -p "$fw/Modules/$module.swiftmodule"
    cp "$products/lib$module.a" "$fw/$module"
    cp "$products/$module.swiftmodule/$suffix.swiftmodule" "$fw/Modules/$module.swiftmodule/"
    cp "$products/$module.swiftmodule/$suffix.abi.json" "$fw/Modules/$module.swiftmodule/"
    cp "$products/$module.swiftmodule/$suffix.swiftdoc" "$fw/Modules/$module.swiftmodule/"
    cat >"$fw/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$module</string>
  <key>CFBundleIdentifier</key><string>org.jitsi.swift.$module</string>
  <key>CFBundleName</key><string>$module</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleSupportedPlatforms</key><array><string>$plist_platform</string></array>
  <key>MinimumOSVersion</key><string>15.0</string>
</dict>
</plist>
PLIST
  done

  # The JS shims live in a SwiftPM resource bundle. A static framework cannot carry resources
  # that reach the app on its own, so the bundle ships beside the frameworks and the host app
  # copies it into its own Resources (Bundle.module looks there first).
  if [ -d "$products/JitsiMeetSDK_JitsiJSRuntime.bundle" ] && [ ! -d "$DIST/JitsiMeetSDK_JitsiJSRuntime.bundle" ]; then
    cp -R "$products/JitsiMeetSDK_JitsiJSRuntime.bundle" "$DIST/"
  fi
}

build_platform ios-arm64 arm64-apple-ios15.0 iphoneos arm64-apple-ios iPhoneOS
build_platform ios-arm64-simulator arm64-apple-ios15.0-simulator iphonesimulator arm64-apple-ios-simulator iPhoneSimulator

# `xcodebuild -create-xcframework` refuses slices without a `.swiftinterface` next to each
# `.swiftmodule`, and SwiftPM does not emit interfaces for static products. The container is a
# plain directory plus an Info.plist, so it is written directly; the compiler still resolves the
# module from the `.swiftmodule`, which the same toolchain that builds the host app produces.
assemble_xcframework() { # $1 = module
  local module="$1" out="$DIST/$1.xcframework"
  rm -rf "$out"
  mkdir -p "$out/ios-arm64" "$out/ios-arm64-simulator"
  cp -R "$STAGE/ios-arm64/$module.framework" "$out/ios-arm64/"
  cp -R "$STAGE/ios-arm64-simulator/$module.framework" "$out/ios-arm64-simulator/"
  cat >"$out/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundlePackageType</key><string>XFWK</string>
  <key>XCFrameworkFormatVersion</key><string>1.0</string>
  <key>AvailableLibraries</key>
  <array>
    <dict>
      <key>BinaryPath</key><string>$module.framework/$module</string>
      <key>LibraryIdentifier</key><string>ios-arm64</string>
      <key>LibraryPath</key><string>$module.framework</string>
      <key>SupportedArchitectures</key><array><string>arm64</string></array>
      <key>SupportedPlatform</key><string>ios</string>
    </dict>
    <dict>
      <key>BinaryPath</key><string>$module.framework/$module</string>
      <key>LibraryIdentifier</key><string>ios-arm64-simulator</string>
      <key>LibraryPath</key><string>$module.framework</string>
      <key>SupportedArchitectures</key><array><string>arm64</string></array>
      <key>SupportedPlatform</key><string>ios</string>
      <key>SupportedPlatformVariant</key><string>simulator</string>
    </dict>
  </array>
</dict>
</plist>
PLIST
}

for module in "${MODULES[@]}"; do
  assemble_xcframework "$module"
done

cp -R Frameworks/WebRTC.xcframework "$DIST/"
cp Frameworks/WebRTC-LICENSE.txt "$DIST/" 2>/dev/null || true

echo
echo "packaged into $DIST/"
for module in "${MODULES[@]}"; do
  printf '  %-20s %s\n' "$module.xcframework" "$(du -sh "$DIST/$module.xcframework" | cut -f1)"
done
printf '  %-20s %s\n' "WebRTC.xcframework" "$(du -sh "$DIST/WebRTC.xcframework" | cut -f1)"
echo
echo "The host app must copy $DIST/JitsiMeetSDK_JitsiJSRuntime.bundle into its Resources;"
echo "without it the JS runtime hits a fatalError('unable to find bundle') on first bootstrap."
