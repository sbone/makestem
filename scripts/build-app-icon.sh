#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
source_icon="${1:-$repo_root/artwork/MakestemIcon.png}"
icon_set="$repo_root/macos/Assets.xcassets/AppIcon.appiconset"

fail() {
  echo "App icon generation failed: $1" >&2
  exit 1
}

[[ -f "$source_icon" ]] || fail \
  "Source PNG not found at $source_icon. Add a square PNG of at least 1024 x 1024 pixels."

metadata="$(sips -g format -g pixelWidth -g pixelHeight "$source_icon" 2>/dev/null)" \
  || fail "Could not read $source_icon. Confirm that it is a valid PNG file."
format="$(awk '/format:/ { print $2 }' <<< "$metadata")"
width="$(awk '/pixelWidth:/ { print $2 }' <<< "$metadata")"
height="$(awk '/pixelHeight:/ { print $2 }' <<< "$metadata")"

[[ "$format" == "png" ]] || fail "Source must be a PNG; found ${format:-unknown format}."
[[ "$width" == <-> && "$height" == <-> ]] || fail "Could not determine the image dimensions."
[[ "$width" == "$height" ]] || fail "Source must be square; found ${width} x ${height} pixels."
(( width >= 1024 )) || fail "Source must be at least 1024 x 1024 pixels; found ${width} x ${height}."

mkdir -p "$icon_set"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$source_icon" --out "$icon_set/icon_${size}x${size}.png" >/dev/null
  doubled=$(( size * 2 ))
  sips -z "$doubled" "$doubled" "$source_icon" --out "$icon_set/icon_${size}x${size}@2x.png" >/dev/null
done

echo "Generated Makestem app icons from $source_icon"
