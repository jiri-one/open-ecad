#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Development helper: original SVG -> platform assets (librsvg + ImageMagick).
set -euo pipefail
cd "$(dirname "$0")/.."
command -v rsvg-convert >/dev/null
command -v magick >/dev/null
for pixels in 16 32 64 128 256 512 1024; do
  rsvg-convert -w "$pixels" -h "$pixels" assets/brand/open-ecad.svg \
    -o "macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_${pixels}.png"
done
rsvg-convert -w 32 -h 32 assets/brand/open-ecad.svg -o web/favicon.png
for pixels in 192 512; do
  rsvg-convert -w "$pixels" -h "$pixels" assets/brand/open-ecad.svg \
    -o "web/icons/Icon-${pixels}.png"
  # Leave a safe margin for platform masks.
  magick "web/icons/Icon-${pixels}.png" -resize 72% -background white \
    -gravity center -extent "${pixels}x${pixels}" "web/icons/Icon-maskable-${pixels}.png"
done
magick macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_256.png \
  -define icon:auto-resize=256,128,64,48,32,16 windows/runner/resources/app_icon.ico
