#!/bin/bash
# Regenerates every icon from scripts/make-icon.swift:
#   app:    Support/AppIcon.icns (16–1024 px, @1x and @2x)
#   README: ../docs/images/icon.png
set -euo pipefail
cd "$(dirname "$0")/.."

MASTER="$(mktemp -d)/AppIcon-1024.png"
swift scripts/make-icon.swift "$MASTER"

ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size "$MASTER" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) "$MASTER" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o Support/AppIcon.icns

mkdir -p ../docs/images
sips -z 256 256 "$MASTER" --out ../docs/images/icon.png >/dev/null
echo "Icons written."
