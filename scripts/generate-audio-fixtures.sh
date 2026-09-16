#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
ffmpeg="${MAKESTEM_FIXTURE_FFMPEG:-$(command -v ffmpeg || true)}"
fixtures="$repo_root/tests/fixtures/audio"
work="$(mktemp -d "${TMPDIR:-/tmp}/makestem-fixtures.XXXXXX")"
trap 'rm -rf "$work"' EXIT

[[ -x "$ffmpeg" ]] || {
  echo "Fixture generation requires a full FFmpeg installation." >&2
  echo "Install FFmpeg or set MAKESTEM_FIXTURE_FFMPEG, then retry." >&2
  exit 1
}

mkdir -p "$fixtures"
dd if="$repo_root/artwork/MakestemIcon.png" of="$work/source.pcm" \
  bs=176400 count=1 2>/dev/null
cp "$repo_root/macos/Assets.xcassets/AppIcon.appiconset/icon_16x16.png" "$work/cover.png"

common=(-hide_banner -loglevel error -y -f s16le -ar 44100 -ac 2 -i "$work/source.pcm")
metadata=(-metadata 'artist=Fixture Artist' -metadata 'title=Fixture Track')

"$ffmpeg" $common -c:a pcm_s16le $metadata "$fixtures/pcm-16.wav"
"$ffmpeg" $common -ac 1 -c:a pcm_s16le $metadata "$fixtures/mono.wav"
"$ffmpeg" $common -ac 6 -c:a pcm_s16le $metadata "$fixtures/multichannel.wav"
"$ffmpeg" $common -c:a pcm_s24le $metadata "$fixtures/pcm-24.wav"
"$ffmpeg" $common -c:a pcm_f32le $metadata "$fixtures/stem-f32.wav"
"$ffmpeg" $common -c:a pcm_s24be $metadata "$fixtures/lossless.aiff"
"$ffmpeg" $common -c:a flac $metadata "$fixtures/lossless.flac"
"$ffmpeg" $common -c:a alac $metadata "$fixtures/lossless-alac.m4a"
"$ffmpeg" $common -c:a libmp3lame -b:a 192k \
  -metadata 'artist=Beyoncé & Friends' \
  -metadata 'title=Odd — “Tags” 🎧' \
  "$fixtures/cbr-unicode.mp3"
"$ffmpeg" $common -c:a libmp3lame -q:a 2 $metadata "$work/vbr.mp3"
"$ffmpeg" -hide_banner -loglevel error -y \
  -i "$work/vbr.mp3" -i "$work/cover.png" \
  -map 0:a:0 -map 1:v:0 -c copy -id3v2_version 3 \
  -metadata 'artist=Fixture Artist' -metadata 'title=VBR With Artwork' \
  -metadata:s:v 'title=Album cover' -disposition:v attached_pic \
  "$fixtures/vbr-artwork.mp3"
"$ffmpeg" $common -c:a aac -b:a 160k $metadata "$fixtures/compressed-aac.m4a"
"$ffmpeg" $common -c:a aac -b:a 160k -f adts $metadata "$fixtures/compressed.aac"
"$ffmpeg" $common -c:a vorbis -strict experimental -b:a 160k $metadata "$fixtures/compressed-vorbis.ogg"
"$ffmpeg" $common -c:a opus -strict experimental -b:a 128k $metadata "$fixtures/compressed-opus.ogg"

printf 'not an audio file' > "$fixtures/damaged.m4a"
cp "$work/cover.png" "$fixtures/artwork-only.png"

echo "Generated audio fixtures in $fixtures"
