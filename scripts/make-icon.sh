#!/bin/bash
# Renders the icon sources in docs/ into the app's resources. Needs rsvg-convert (brew install librsvg).
#   docs/icon.svg, docs/icon-32.svg, docs/icon-16.svg -> Resources/AppIcon.icns (the small sizes have their own drawings)
#   docs/menubar/<state>.svg -> Resources/MenuBar/<state>.png and <state>@2x.png (template images, 22 and 44 px;
#   PNG, not PDF: the glyphs use an SVG mask, which rsvg-convert loses when it writes a PDF)
set -euo pipefail
cd "$(dirname "$0")/.."
SET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$SET"
png() { rsvg-convert -w "$2" -h "$2" "$1" -o "$SET/$3"; }
png docs/icon-16.svg 16 icon_16x16.png
png docs/icon-32.svg 32 icon_16x16@2x.png
png docs/icon-32.svg 32 icon_32x32.png
png docs/icon-32.svg 64 icon_32x32@2x.png
for size in 128 256 512; do
  png docs/icon.svg $size icon_${size}x${size}.png
  png docs/icon.svg $((size * 2)) icon_${size}x${size}@2x.png
done
iconutil -c icns "$SET" -o Resources/AppIcon.icns
rm -rf Resources/MenuBar
mkdir -p Resources/MenuBar
for state in idle recording paused transcribing waiting; do
  rsvg-convert -w 22 -h 22 docs/menubar/$state.svg -o Resources/MenuBar/$state.png
  rsvg-convert -w 44 -h 44 docs/menubar/$state.svg -o Resources/MenuBar/$state@2x.png
done
echo "wrote Resources/AppIcon.icns and Resources/MenuBar/*.png"
