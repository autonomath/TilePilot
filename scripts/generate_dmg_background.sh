#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_PATH="${1:-$ROOT_DIR/assets/dmg/dmg-background.png}"
BASE_PATH="$ROOT_DIR/assets/dmg/dmg-background-base.png"

if ! command -v magick >/dev/null 2>&1; then
  echo "ImageMagick (magick) is required to generate the DMG background." >&2
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT_PATH")"

if [[ ! -f "$BASE_PATH" ]]; then
  echo "ImageGen DMG background base is missing: $BASE_PATH" >&2
  exit 1
fi

magick "$BASE_PATH" -resize '900x530^' -gravity center -extent 900x530 \
  -fill '#FFFFFF12' -draw "circle 235,340 235,455" \
  -fill '#FFFFFF10' -draw "circle 665,340 665,455" \
  -stroke '#E2E8F0E6' -strokewidth 7 -fill none \
  -draw "path 'M 330,340 C 415,275 485,275 545,310'" \
  -fill '#E2E8F0E6' -stroke none -draw "polygon 575,330 540,321 557,295" \
  -fill '#F8FAFC' -font 'Helvetica-Bold' -pointsize 48 -gravity north -annotate +0+52 'Install TilePilot' \
  -fill '#CBD5E1' -font 'Helvetica' -pointsize 24 -gravity north -annotate +0+115 'Drag TilePilot to Applications' \
  "$OUTPUT_PATH"

echo "Generated DMG background:"
echo "  $OUTPUT_PATH"
