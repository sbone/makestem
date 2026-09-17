#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
app="$repo_root/build/Makestem.app"
executable="$app/Contents/MacOS/Makestem"
destination="$repo_root/screenshots"

window_id() {
  local process_id="$1"
  swift -e '
    import CoreGraphics
    import Foundation
    guard let wanted = Int(CommandLine.arguments[1]) else {
      fatalError("Invalid process identifier")
    }
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
      as? [[String: Any]] ?? []
    var best: (number: Int, area: Double)?
    for window in windows {
      let owner = window[kCGWindowOwnerPID as String] as? Int
      let layer = window[kCGWindowLayer as String] as? Int
      if owner == wanted, layer == 0,
         let number = window[kCGWindowNumber as String] as? Int,
         let bounds = window[kCGWindowBounds as String] as? [String: Any],
         let width = bounds["Width"] as? NSNumber,
         let height = bounds["Height"] as? NSNumber {
        let candidate = (number, width.doubleValue * height.doubleValue)
        if let current = best, candidate.1 > current.area {
          best = candidate
        } else if best == nil {
          best = candidate
        }
      }
    }
    if let best { print(best.number) }
  ' "$process_id"
}

activate() {
  local process_id="$1"
  swift -e '
    import AppKit
    guard let processID = Int32(CommandLine.arguments[1]),
          let app = NSRunningApplication(processIdentifier: processID) else {
      fatalError("Makestem is not running")
    }
    app.activate(options: [.activateAllWindows])
  ' "$process_id"
}

capture() {
  local state="$1"
  local filename="$2"
  local process_id id

  "$executable" \
    -ApplePersistenceIgnoreState YES \
    -NSQuitAlwaysKeepsWindows NO \
    --screenshot-state "$state" &
  process_id=$!
  trap 'kill "$process_id" 2>/dev/null || true' EXIT INT TERM

  for _ in {1..50}; do
    id="$(window_id "$process_id")"
    [[ -n "$id" ]] && break
    sleep 0.2
  done
  [[ -n "${id:-}" ]] || {
    echo "Makestem did not open a window for screenshot state: $state" >&2
    exit 1
  }

  activate "$process_id"
  sleep 4
  screencapture -x -o -l "$id" "$destination/$filename"
  sips -g pixelWidth -g pixelHeight "$destination/$filename" >/dev/null
  [[ "$(stat -f %z "$destination/$filename")" -gt 20000 ]] || {
    echo "Screenshot appears blank. Allow screen recording for your terminal or editor." >&2
    exit 1
  }

  kill "$process_id" 2>/dev/null || true
  wait "$process_id" 2>/dev/null || true
  trap - EXIT INT TERM
  echo "Captured $filename"
}

mkdir -p "$destination"
cd "$repo_root"
MAKESTEM_BUILD_CONFIGURATION=Debug ./scripts/build-mac-app.sh

pkill -x Makestem 2>/dev/null || true
sleep 0.5

capture ready makestem-ready.png
capture loaded-compressed makestem-track-loaded.png
capture processing makestem-processing.png

echo "Screenshots saved in $destination"
