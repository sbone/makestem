#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
project="$repo_root/macos/MakeStem.xcodeproj"
derived_data="$repo_root/build/xcode-derived"

cd "$repo_root"
xcodebuild \
  -project "$project" \
  -scheme MakeStem \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$derived_data" \
  CONFIGURATION_BUILD_DIR="$repo_root/build" \
  CODE_SIGN_IDENTITY=- \
  build

echo "Built $repo_root/build/MakeStem.app"
