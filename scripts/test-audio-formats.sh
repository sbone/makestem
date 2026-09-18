#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
tools="${1:-$repo_root/build/Makestem.app/Contents/Resources/bin}"
cli="${2:-$repo_root/build/Makestem.app/Contents/Helpers/makestem}"
fixtures="$repo_root/tests/fixtures/audio"
work="$(mktemp -d "${TMPDIR:-/tmp}/makestem-formats.XXXXXX")"
trap 'rm -rf "$work"' EXIT

ffmpeg="$tools/ffmpeg"
ffprobe="$tools/ffprobe"
for executable in "$cli" "$ffmpeg" "$ffprobe"; do
  [[ -x "$executable" ]] || {
    echo "Audio-format test executable is missing: $executable" >&2
    exit 1
  }
done

json_value() {
  /usr/bin/plutil -extract "$2" raw -o - "$1"
}

inspect() {
  local source="$1"
  local destination="$2"
  PATH="$tools:/usr/bin:/bin" "$cli" --inspect-json "$source" > "$destination"
}

assert_equal() {
  local actual="$1"
  local expected="$2"
  local label="$3"
  [[ "$actual" == "$expected" ]] || {
    echo "$label: expected '$expected', got '$actual'" >&2
    exit 1
  }
}

assert_contains() {
  local actual="$1"
  local expected="$2"
  local label="$3"
  [[ "$actual" == *"$expected"* ]] || {
    echo "$label: expected '$actual' to contain '$expected'" >&2
    exit 1
  }
}

typeset -a matrix=(
  'pcm-16.wav|WAV|pcm_s16le|true|ready|320 kbps MP3|44100|2'
  'mono.wav|WAV|pcm_s16le|true|ready|320 kbps MP3|44100|1'
  'pcm-24.wav|WAV|pcm_s24le|true|ready|320 kbps MP3|44100|2'
  'stem-f32.wav|WAV|pcm_f32le|true|ready|320 kbps MP3|44100|2'
  'lossless.aiff|AIFF|pcm_s24be|true|ready|320 kbps MP3|44100|2'
  'lossless.flac|FLAC|flac|true|ready|320 kbps MP3|44100|2'
  'lossless-alac.m4a|ALAC|alac|true|ready|320 kbps MP3|44100|2'
  'cbr-unicode.mp3|MP3|mp3|false|warning|192 kbps MP3|44100|2'
  'vbr-artwork.mp3|MP3|mp3|false|warning|VBR quality|44100|2'
  'compressed-aac.m4a|AAC|aac|false|warning|160 kbps MP3|44100|2'
  'compressed.aac|AAC|aac|false|warning|160 kbps MP3|44100|2'
  'compressed-vorbis.ogg|VORBIS|vorbis|false|warning|320 kbps MP3|44100|2'
  'compressed-opus.ogg|OPUS|opus|false|warning|128 kbps MP3|48000|2'
)

echo "==> Inspecting supported audio matrix"
for row in $matrix; do
  IFS='|' read -r file format codec lossless readiness quality sample_rate channels <<< "$row"
  result="$work/$file.json"
  inspect "$fixtures/$file" "$result"
  assert_equal "$(json_value "$result" format)" "$format" "$file format"
  assert_equal "$(json_value "$result" codec)" "$codec" "$file codec"
  assert_equal "$(json_value "$result" lossless)" "$lossless" "$file lossless"
  assert_equal "$(json_value "$result" readiness)" "$readiness" "$file readiness"
  assert_contains "$(json_value "$result" output_quality)" "$quality" "$file output quality"
  assert_equal "$(json_value "$result" channels)" "$channels" "$file channels"
  assert_equal "$(json_value "$result" sample_rate)" "$sample_rate" "$file sample rate"
done

cbr_result="$work/cbr.json"
inspect "$fixtures/cbr-unicode.mp3" "$cbr_result"
assert_equal "$(json_value "$cbr_result" artist)" 'Beyoncé & Friends' 'Unicode artist metadata'
assert_equal "$(json_value "$cbr_result" title)" 'Odd — “Tags” 🎧' 'Unicode title metadata'

artwork_result="$work/artwork.json"
inspect "$fixtures/vbr-artwork.mp3" "$artwork_result"
assert_equal "$(json_value "$artwork_result" title)" 'VBR With Artwork' 'Artwork MP3 title'
assert_equal "$(json_value "$artwork_result" source_vbr)" true 'Artwork MP3 VBR detection'

multichannel_result="$work/multichannel.json"
inspect "$fixtures/multichannel.wav" "$multichannel_result"
assert_equal "$(json_value "$multichannel_result" channels)" 6 'Multichannel channel count'
assert_equal "$(json_value "$multichannel_result" readiness)" blocked 'Multichannel readiness'

echo "==> Encoding acapella-style outputs across source containers"
for row in $matrix; do
  IFS='|' read -r file _ <<< "$row"
  output="$work/${file:r}-acapella.mp3"
  "$ffmpeg" -hide_banner -loglevel error -y \
    -i "$fixtures/stem-f32.wav" -i "$fixtures/$file" \
    -map 0:a:0 -map_metadata 1 -metadata 'title=Fixture Track (Acapella)' \
    -c:a libmp3lame -b:a 320k "$output"
  assert_equal "$($ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$output")" mp3 "$file output codec"
  assert_equal "$($ffprobe -v error -show_entries format_tags=title -of default=nw=1:nk=1 "$output")" 'Fixture Track (Acapella)' "$file output title"
done

cbr_output="$work/cbr-unicode-acapella.mp3"
assert_equal "$($ffprobe -v error -select_streams a:0 -show_entries stream=bit_rate -of default=nw=1:nk=1 "$cbr_output")" 320000 '320 kbps output bitrate'
assert_equal "$($ffprobe -v error -show_entries format_tags=artist -of default=nw=1:nk=1 "$cbr_output")" 'Beyoncé & Friends' 'Output artist metadata'
artwork_output="$work/vbr-artwork-acapella.mp3"
assert_equal "$($ffprobe -v error -select_streams v -show_entries stream=index -of csv=p=0 "$artwork_output")" '' 'Acapella artwork exclusion'

echo "==> Mixing instrumental-style output"
mixed="$work/instrumental.mp3"
"$ffmpeg" -hide_banner -loglevel error -y \
  -i "$fixtures/stem-f32.wav" -i "$fixtures/stem-f32.wav" -i "$fixtures/stem-f32.wav" \
  -i "$fixtures/vbr-artwork.mp3" \
  -filter_complex 'amix=inputs=3:duration=longest:normalize=0[mixed]' \
  -map '[mixed]' -map_metadata 3 -metadata 'title=VBR With Artwork (Instrumental)' \
  -c:a libmp3lame -q:a 2 "$mixed"
assert_equal "$($ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$mixed")" mp3 'Instrumental codec'
assert_equal "$($ffprobe -v error -show_entries format_tags=title -of default=nw=1:nk=1 "$mixed")" 'VBR With Artwork (Instrumental)' 'Instrumental title'
assert_equal "$($ffprobe -v error -select_streams v -show_entries stream=index -of csv=p=0 "$mixed")" '' 'Instrumental artwork exclusion'
mixed_result="$work/instrumental.json"
inspect "$mixed" "$mixed_result"
assert_equal "$(json_value "$mixed_result" source_vbr)" true 'Instrumental VBR encoding'

echo "==> Sanitizing non-finite stem samples"
nan_stem="$work/non-finite.wav"
safe_output="$work/non-finite.mp3"
"$ffmpeg" -hide_banner -loglevel error -y \
  -i "$fixtures/stem-f32.wav" -af 'aeval=0/0:c=same' -c:a pcm_f32le "$nan_stem"
"$ffmpeg" -hide_banner -loglevel error -y \
  -i "$nan_stem" \
  -af 'aeval=if(isnan(val(ch))+isinf(val(ch))\,0\,val(ch)):c=same' \
  -c:a libmp3lame -b:a 320k "$safe_output"
assert_equal "$("$ffprobe" -v error -select_streams a:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$safe_output")" mp3 'Non-finite sample sanitization'

echo "==> Rejecting malformed and non-audio files"
if PATH="$tools:/usr/bin:/bin" "$cli" --inspect-json "$fixtures/damaged.m4a" > /dev/null 2> "$work/damaged.txt"; then
  echo "Damaged M4A was unexpectedly accepted." >&2
  exit 1
fi
assert_contains "$(<"$work/damaged.txt")" 'Invalid data' 'Damaged M4A error'
if PATH="$tools:/usr/bin:/bin" "$cli" --inspect-json "$fixtures/artwork-only.png" > /dev/null 2> "$work/artwork-only.txt"; then
  echo "Artwork-only file was unexpectedly accepted." >&2
  exit 1
fi
assert_contains "$(<"$work/artwork-only.txt")" 'audio stream' 'Artwork-only error'

echo "Audio-format regression matrix passed"
