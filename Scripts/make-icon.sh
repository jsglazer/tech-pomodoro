#!/bin/bash
#
# make-icon.sh — (re)generate the app icon set from the rendered base glyph.
# Run this only when you want to change the artwork; the PNGs are checked in, so a normal packaging
# run (make-dmg.sh) does not need it. Uses only swift, sips and iconutil — all built into macOS.
#
set -euo pipefail
cd "$(dirname "$0")/.."

ICONSET_DIR="Sources/TechPomodoroApp/Resources/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$ICONSET_DIR"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> rendering base icon"
swift Scripts/makeicon.swift "$TMP/icon_1024.png"

echo "==> scaling icon set members"
sips -z 16 16   "$TMP/icon_1024.png" --out "$ICONSET_DIR/icon_16x16.png"      >/dev/null
sips -z 32 32   "$TMP/icon_1024.png" --out "$ICONSET_DIR/icon_16x16@2x.png"   >/dev/null
sips -z 32 32   "$TMP/icon_1024.png" --out "$ICONSET_DIR/icon_32x32.png"      >/dev/null
sips -z 64 64   "$TMP/icon_1024.png" --out "$ICONSET_DIR/icon_32x32@2x.png"   >/dev/null
sips -z 128 128 "$TMP/icon_1024.png" --out "$ICONSET_DIR/icon_128x128.png"    >/dev/null
sips -z 256 256 "$TMP/icon_1024.png" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$TMP/icon_1024.png" --out "$ICONSET_DIR/icon_256x256.png"    >/dev/null
sips -z 512 512 "$TMP/icon_1024.png" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$TMP/icon_1024.png" --out "$ICONSET_DIR/icon_512x512.png"    >/dev/null
cp              "$TMP/icon_1024.png"        "$ICONSET_DIR/icon_512x512@2x.png"

# A .icns beside the asset catalogue, for anything that wants the icon outside an Xcode build.
ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
cp "$ICONSET_DIR"/icon_*.png "$ICONSET/"
iconutil -c icns "$ICONSET" -o "Sources/TechPomodoroApp/Resources/AppIcon.icns"

echo "wrote $ICONSET_DIR and Sources/TechPomodoroApp/Resources/AppIcon.icns"
