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

echo "==> Building Mac app"
./scripts/build-mac-app.sh

echo "==> Validating packaged Mac app"
./scripts/validate-mac-app.sh

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
  PATH="$repo_root/build/MakeStem.app/Contents/Resources/bin:/usr/bin:/bin" \
    "$repo_root/build/MakeStem.app/Contents/Helpers/makestem" \
    --acapella "$MAKESTEM_SMOKE_TRACK"
fi

echo "==> All checks passed"
