#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
app="${1:-$repo_root/build/MakeStem.app}"
contents="$app/Contents"
plist="$contents/Info.plist"
executables=(
  "$contents/MacOS/MakeStem"
  "$contents/Helpers/makestem"
  "$contents/Resources/bin/demucs"
  "$contents/Resources/bin/ffmpeg"
  "$contents/Resources/bin/ffprobe"
)

fail() {
  echo "App validation failed: $1" >&2
  exit 1
}

version_is_at_most() {
  awk -v actual="$1" -v maximum="$2" 'BEGIN {
    split(actual, a, "."); split(maximum, m, ".")
    exit !((a[1] < m[1]) || (a[1] == m[1] && a[2] <= m[2]))
  }'
}

[[ -d "$app" ]] || fail "MakeStem.app was not found."
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$plist")" == "Makestem" ]] || fail "Unexpected display name."
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")" == "com.stevenbone.makestem" ]] || fail "Unexpected bundle identifier."
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$plist")" == "14.0" ]] || fail "Unexpected minimum macOS version."

for executable in "${executables[@]}"; do
  [[ -x "$executable" ]] || fail "Missing executable: $executable"
  file "$executable" | grep -q "arm64" || fail "$executable does not contain arm64 code."
  minos="$(vtool -show-build "$executable" 2>/dev/null | awk '/minos/ { print $2; exit }')"
  [[ -n "$minos" ]] || fail "Could not read the deployment target for $executable."
  if ! version_is_at_most "$minos" "14.0"; then
    fail "$executable requires macOS $minos, newer than the advertised macOS 14.0."
  fi
  if otool -L "$executable" | tail -n +2 | grep -Eq '/opt/homebrew|/usr/local|/build/dependencies'; then
    fail "$executable links to a non-system build dependency."
  fi
done

"$contents/Resources/bin/demucs" --help >/dev/null
"$contents/Resources/bin/ffmpeg" -hide_banner -encoders 2>/dev/null | grep -q libmp3lame || fail "FFmpeg lacks libmp3lame."
"$contents/Resources/bin/ffprobe" -version >/dev/null
"$contents/Helpers/makestem" --help | grep -q 'Usage: makestem' || fail "The CLI helper did not start correctly."

[[ -f "$contents/Resources/Third-Party Notices.md" ]] || fail "Third-party notices are missing."
for license in FFmpeg-LGPL-2.1.txt LAME-LGPL-2.0.txt demucs-rs-Apache-2.0.txt Demucs-model-MIT.txt; do
  [[ -f "$contents/Resources/Licenses/$license" ]] || fail "Missing license: $license"
done

codesign --verify --deep --strict --verbose=2 "$app"
echo "Validated $app"
