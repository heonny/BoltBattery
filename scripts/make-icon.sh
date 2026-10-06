#!/bin/sh
# Generate standard and Retina representations from the app icon master.
set -eu
cd "$(dirname "$0")/.."
ICONSET=.build/AppIcon.iconset
mkdir -p "$ICONSET"
for SIZE in 16 32 128 256 512; do
    sips -z "$SIZE" "$SIZE" Packaging/AppIcon.png --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
    RETINA=$((SIZE * 2))
    sips -z "$RETINA" "$RETINA" Packaging/AppIcon.png --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o .build/AppIcon.icns
