#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
cd "$repo_root"

echo "==> Formatting"
cargo fmt --check

echo "==> Rust tests and CLI contracts"
cargo test --locked

echo "==> Rust lint"
cargo clippy --locked --all-targets -- -D warnings

echo "==> Building pinned FFmpeg tools"
./scripts/build-ffmpeg-macos.sh

echo "==> Swift unit tests"
xcodebuild \
  -project macos/Makestem.xcodeproj \
  -scheme Makestem \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath build/xcode-tests \
  CODE_SIGN_IDENTITY=- \
  test

echo "==> Building Mac app"
./scripts/build-mac-app.sh

echo "==> Validating packaged Mac app"
./scripts/validate-mac-app.sh

echo "==> Audio-format regression matrix"
./scripts/test-audio-formats.sh

if [[ "${MAKESTEM_REAL_AUDIO_SMOKE:-0}" == "1" ]]; then
  [[ -n "${MAKESTEM_SMOKE_TRACK:-}" ]] || {
    echo "MAKESTEM_SMOKE_TRACK is required when MAKESTEM_REAL_AUDIO_SMOKE=1." >&2
    exit 1
  }
  [[ -f "$MAKESTEM_SMOKE_TRACK" ]] || {
    echo "Smoke-test track not found: $MAKESTEM_SMOKE_TRACK" >&2
    exit 1
  }
  echo "==> Real audio smoke test"
  PATH="$repo_root/build/Makestem.app/Contents/Resources/bin:/usr/bin:/bin" \
    "$repo_root/build/Makestem.app/Contents/Helpers/makestem" \
    --acapella "$MAKESTEM_SMOKE_TRACK"
  smoke_output="${MAKESTEM_SMOKE_TRACK:h}/output/${MAKESTEM_SMOKE_TRACK:t:r} (Acapella).mp3"
  [[ -s "$smoke_output" ]] || {
    echo "Smoke-test output was not created: $smoke_output" >&2
    exit 1
  }
  smoke_title="$("$repo_root/build/dependencies/bin/ffprobe" -v error \
    -show_entries format_tags=title -of default=noprint_wrappers=1:nokey=1 \
    "$smoke_output")"
  [[ "$smoke_title" == *" (Acapella)" ]] || {
    echo "Smoke-test output title is incorrect: $smoke_title" >&2
    exit 1
  }
fi

echo "==> All checks passed"
