#!/usr/bin/env bash
# Build lib-jitsi-meet's own UMD bundle and install it into JitsiJSRuntime's resources,
# where JavaScriptCore loads it last (see Resources/js/99-lib-jitsi-meet.bundle.js).
#
# Usage: ./Scripts/build-js-bundle.sh [/path/to/lib-jitsi-meet]
set -euo pipefail

LIB_DIR="${1:-$HOME/Downloads/lib-jitsi-meet-master}"
JS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/Sources/JitsiJSRuntime/Resources/js"
DEST="$JS_DIR/99-lib-jitsi-meet.bundle.js"

if [[ ! -f "$LIB_DIR/package.json" ]]; then
  echo "not a lib-jitsi-meet checkout: $LIB_DIR" >&2
  echo "usage: $0 [/path/to/lib-jitsi-meet]" >&2
  exit 1
fi

cd "$LIB_DIR"
node --version
npm ci --no-audit --no-fund

# `npm run build` also runs `build:tsc`, which only emits .d.ts and fails the whole step on
# unrelated type errors; the runtime needs the webpack bundle, so build that directly.
npm run gen-version
npx webpack

BUNDLE="$LIB_DIR/dist/umd/lib-jitsi-meet.min.js"
if [[ ! -f "$BUNDLE" ]]; then
  echo "expected bundle missing: $BUNDLE" >&2
  exit 1
fi

cp "$BUNDLE" "$DEST"
# The minified file carries an attribution comment naming this file; keep it next to the bundle.
if [[ -f "$LIB_DIR/dist/umd/lib-jitsi-meet.min.js.LICENSE.txt" ]]; then
  cp "$LIB_DIR/dist/umd/lib-jitsi-meet.min.js.LICENSE.txt" "$JS_DIR/98-lib-jitsi-meet.LICENSE.txt"
fi
echo "installed $(wc -c < "$DEST") bytes -> $DEST"

# The bundle is a build artifact, not source: note where it came from so a stale copy is
# traceable instead of mysterious.
{
  printf '\n'
  echo "// source: $LIB_DIR @ $(git -C "$LIB_DIR" rev-parse --short HEAD 2>/dev/null || echo 'unversioned copy')"
  echo "// built: $(date -u +%Y-%m-%dT%H:%MZ) by Scripts/build-js-bundle.sh (webpack, dist/umd/lib-jitsi-meet.min.js)"
} >> "$DEST"

# E2EE needs this second artifact as well once the Worker bridge lands (phase 4); it is not
# loaded today, so it is only reported.
echo "also available: $(wc -c < "$LIB_DIR/dist/umd/lib-jitsi-meet.e2ee-worker.js") bytes of E2EE worker bundle (not installed)"
