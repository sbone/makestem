#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
app="${1:-$repo_root/build/Makestem.app}"
executable="$app/Contents/MacOS/Makestem"
log="$(mktemp "${TMPDIR:-/tmp}/makestem-launch.XXXXXX")"
pid=""

cleanup() {
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid"
    wait "$pid" 2>/dev/null || true
  fi
  rm -f "$log"
}
trap cleanup EXIT

[[ -x "$executable" ]] || {
  echo "Launch test failed: executable not found at $executable" >&2
  exit 1
}

"$executable" >"$log" 2>&1 &
pid=$!
sleep 2

if ! kill -0 "$pid" 2>/dev/null; then
  wait "$pid" 2>/dev/null || exit_status=$?
  echo "Launch test failed: Makestem exited during startup (status ${exit_status:-unknown})." >&2
  [[ ! -s "$log" ]] || cat "$log" >&2
  exit 1
fi

echo "Launch-tested $app"
