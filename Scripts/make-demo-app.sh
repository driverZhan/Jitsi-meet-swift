#!/usr/bin/env bash
# Assemble the demo host app out of SwiftPM's simulator build, then optionally install and
# launch it. A bare SwiftPM executable has no bundle, and iOS will not start a UIKit or
# SwiftUI app without one, so this script creates the bundle by hand.
set -euo pipefail
cd "$(dirname "$0")/.."

DEVICE="${SIMULATOR_UDID:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --device)
      DEVICE="$2"
      shift 2
      ;;
    *)
      echo "usage: $0 [--device <simulator-udid>]" >&2
      exit 2
      ;;
  esac
done

SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
swift build --triple arm64-apple-ios15.0-simulator --sdk "$SDK"

PRODUCTS=$(cd .build/debug && pwd)
APP=/tmp/JitsiMeetDemo.app
BUNDLE_ID=org.jitsi.swift.demo

rm -rf "$APP"
mkdir -p "$APP/Frameworks"
cp "$PRODUCTS/JitsiMeetDemoApp" "$APP/"
cp -R "$PRODUCTS/JitsiMeetSDK_JitsiJSRuntime.bundle" "$APP/"
cp -R "$PRODUCTS/WebRTC.framework" "$APP/Frameworks/"
cp Scripts/demo-app-Info.plist "$APP/Info.plist"

# SwiftPM points the executable's rpath at its own build directory, which dyld rewrites into
# the simulator runtime root and then fails to find. `@executable_path/Frameworks` is not an
# implicit search path on iOS, so the bundled WebRTC needs it spelled out.
xcrun install_name_tool -add_rpath @executable_path/Frameworks "$APP/JitsiMeetDemoApp"

codesign --force --sign - "$APP/Frameworks/WebRTC.framework"
codesign --force --sign - "$APP"
echo "assembled $APP"

if [ -n "$DEVICE" ]; then
  xcrun simctl install "$DEVICE" "$APP"
  xcrun simctl privacy "$DEVICE" grant camera "$BUNDLE_ID"
  xcrun simctl privacy "$DEVICE" grant microphone "$BUNDLE_ID"
  if [ "${DEMO_AUTOJOIN:-0}" = "1" ]; then
    # `simctl` has no --setenv; child environment comes from SIMCTL_CHILD_ prefixed vars.
    SIMCTL_CHILD_JITSI_DEMO_AUTOJOIN=1 xcrun simctl launch "$DEVICE" "$BUNDLE_ID"
    echo "launched $BUNDLE_ID on $DEVICE"
    # The JS console forwarder writes with NSLog, which goes to os_log, not stderr, so
    # `simctl launch --stderr=` captures nothing.
    echo "console: xcrun simctl spawn $DEVICE log show --last 2m \\"
    echo "           --predicate 'processImagePath CONTAINS \"JitsiMeetDemo\"' | grep jitsi-js"
  else
    xcrun simctl launch "$DEVICE" "$BUNDLE_ID"
    echo "launched $BUNDLE_ID on $DEVICE"
  fi
fi
