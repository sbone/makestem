#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
project="$repo_root/macos/Makestem.xcodeproj"
derived_data="$repo_root/build/xcode-derived"
identity="${MAKESTEM_SIGNING_IDENTITY:--}"
configuration="${MAKESTEM_BUILD_CONFIGURATION:-Release}"
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
  -configuration "$configuration" \
  -destination 'platform=macOS' \
  -derivedDataPath "$derived_data" \
  CONFIGURATION_BUILD_DIR="$repo_root/build" \
  CODE_SIGN_IDENTITY="$identity" \
  build

app="$repo_root/build/Makestem.app"
if [[ "$identity" != "-" ]]; then
  sparkle="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
  for component in \
    "$sparkle/XPCServices/Downloader.xpc" \
    "$sparkle/XPCServices/Installer.xpc" \
    "$sparkle/Updater.app" \
    "$sparkle/Autoupdate" \
    "$sparkle"; do
    codesign --force --sign "$identity" --options runtime --timestamp \
      --preserve-metadata=identifier,entitlements,requirements,flags "$component"
  done
fi

codesign --force --sign "$identity" --options runtime "${signing_flags[@]}" \
  "$app"
echo "Built $app"
