#!/bin/bash
#
# Assembles VSBMNative.app from a SwiftPM release build.
#
# There is no Xcode on this machine (Command Line Tools only) and therefore no
# `metal` compiler, so no .metallib is produced or needed: every shader is
# compiled from source at runtime with MTLDevice.makeLibrary(source:).
# That is also what makes kernel hot-reload possible.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${CONFIG:-release}"
DIST="$ROOT/dist"
APP="$DIST/VSBMNative.app"

echo "==> Building (configuration: $CONFIG)"
cd "$ROOT"
swift build -c "$CONFIG" --product VSBMNative

BIN="$(swift build -c "$CONFIG" --product VSBMNative --show-bin-path)/VSBMNative"
if [[ ! -x "$BIN" ]]; then
  echo "error: expected an executable at $BIN" >&2
  exit 1
fi

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/VSBMNative"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
else
  echo "warning: Resources/AppIcon.icns is missing; run scripts/make-icon.sh" >&2
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Ad-hoc signing"
# An ad-hoc signature is enough for local execution; no Developer ID required.
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 \
  || echo "warning: ad-hoc signing failed; the app still runs locally"

echo "==> Built $APP"
/usr/bin/file "$APP/Contents/MacOS/VSBMNative" | sed 's/^/    /'

cat <<EOF

Run it:

    open "$APP"

Or from a terminal, which is useful for reading diagnostics:

    "$APP/Contents/MacOS/VSBMNative"

Useful flags:

    --preset reference|balanced|performance|raw
    --kernel /path/to/kernel.metal

Verify correctness:

    swift run -c release vsbm-selfcheck
    swift run -c release vsbm-selfcheck --bench     # also prints the performance matrix
EOF
