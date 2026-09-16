#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
project="$repo_root/macos/Makestem.xcodeproj"
derived_data="$repo_root/build/xcode-derived"
identity="${MAKESTEM_SIGNING_IDENTITY:--}"
signing_flags=()
if [[ "$identity" != "-" ]]; then
  signing_flags=(--timestamp)
fi

cd "$repo_root"
if [[ -f "$repo_root/artwork/MakestemIcon.png" ]]; then
  ./scripts/build-app-icon.sh
fi
xcodebuild \
  -quiet \
  -project "$project" \
  -scheme Makestem \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$derived_data" \
  CONFIGURATION_BUILD_DIR="$repo_root/build" \
  CODE_SIGN_IDENTITY="$identity" \
  build

codesign --force --sign "$identity" --options runtime "${signing_flags[@]}" \
  "$repo_root/build/Makestem.app"
echo "Built $repo_root/build/Makestem.app"
