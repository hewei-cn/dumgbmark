#!/bin/bash
#
# Regenerates Resources/AppIcon.icns from a frame rendered by the app itself, so
# the icon always matches what the renderer actually produces.
#
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BIN="$(swift build -c release --product VSBMNative --show-bin-path)/VSBMNative"
if [[ ! -x "$BIN" ]]; then
  echo "==> Building first"
  swift build -c release --product VSBMNative
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Rendering the icon source frame"
"$BIN" --render "$WORK/source.png" --size 1024x1024 --len 1.6 --angle1 2.8 --angle2 0.4

echo "==> Composing the rounded tile and iconset"
swift Tools/make-icon.swift "$WORK/source.png" "$WORK/AppIcon.iconset" 0.88

echo "==> Building the .icns"
iconutil -c icns "$WORK/AppIcon.iconset" -o "$ROOT/Resources/AppIcon.icns"

echo "==> Wrote Resources/AppIcon.icns"
ls -la "$ROOT/Resources/AppIcon.icns"
