#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
app="$repo_root/build/Stemcraft.app"
module_cache="$repo_root/build/swift-module-cache"
command_line_sdk="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
if [[ -n "${SDKROOT:-}" ]]; then
  macos_sdk="$SDKROOT"
elif [[ -d "$command_line_sdk" ]]; then
  macos_sdk="$command_line_sdk"
else
  macos_sdk="$(xcrun --sdk macosx --show-sdk-path)"
fi

cd "$repo_root"
cargo build --release

mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers"
mkdir -p "$module_cache"
cp macos/Info.plist "$app/Contents/Info.plist"
cp target/release/stemcraft "$app/Contents/Helpers/stemcraft"

swiftc \
  -parse-as-library \
  -target arm64-apple-macos14.0 \
  -sdk "$macos_sdk" \
  -module-cache-path "$module_cache" \
  macos/StemcraftApp.swift \
  -o "$app/Contents/MacOS/Stemcraft" \
  -framework SwiftUI \
  -framework AppKit \
  -framework UniformTypeIdentifiers

codesign --force --deep --sign - "$app"
echo "Built $app"
