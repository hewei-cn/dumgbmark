#!/bin/bash
#
# Installs VSBMNative.app so it can be launched from Launchpad, Spotlight or the
# Applications folder.
#
# Why this is a script and not a one-line `cp`: `cp -R src.app /Applications/dst.app`
# behaves differently depending on whether the destination already exists. When
# it does, `cp` copies the bundle *inside* it, producing
# /Applications/VSBMNative.app/VSBMNative.app and silently leaving the old
# binary in place. `ditto` merges and replaces correctly, and the destination is
# removed first as well.
#
# Usage: scripts/install.sh [--no-dock-restart]
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LSR="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
RESTART_DOCK=1
[[ "${1:-}" == "--no-dock-restart" ]] && RESTART_DOCK=0

# /Applications is group-writable by admins; fall back to ~/Applications.
DEST_DIR="/Applications"
if [[ ! -w "$DEST_DIR" ]]; then
  DEST_DIR="$HOME/Applications"
  mkdir -p "$DEST_DIR"
  echo "==> /Applications is not writable; installing to $DEST_DIR"
fi
DEST="$DEST_DIR/VSBMNative.app"

echo "==> Building"
"$ROOT/scripts/build-app.sh"

echo "==> Stopping any running instance"
pkill -f "$DEST/Contents/MacOS/VSBMNative" 2>/dev/null || true
sleep 1

echo "==> Installing to $DEST"
rm -rf "$DEST"
ditto "$ROOT/dist/VSBMNative.app" "$DEST"

echo "==> Verifying"
codesign --verify --verbose=1 "$DEST" 2>&1 | sed 's/^/    /'
test -f "$DEST/Contents/Resources/AppIcon.icns" || echo "    warning: icon missing"
# Guard against the nesting failure described above.
if [[ -d "$DEST/VSBMNative.app" ]]; then
  echo "    error: nested bundle detected; install is corrupt" >&2
  exit 1
fi

echo "==> Registering with Launch Services"
"$LSR" -f "$DEST"
# Unregister the build-tree copy so Spotlight does not offer a duplicate.
"$LSR" -u "$ROOT/dist/VSBMNative.app" 2>/dev/null || true

if [[ "$RESTART_DOCK" == "1" ]]; then
  echo "==> Refreshing the icon cache (the Dock restarts, which takes a moment)"
  touch "$DEST"
  killall Dock 2>/dev/null || true
fi

echo ""
echo "Installed: $DEST"
echo "Launch:    open -b dev.local.vsbmnative"
echo "           or click the icon in Launchpad / Applications"
