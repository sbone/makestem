#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
app="$repo_root/build/MakeStem.app"
module_cache="$repo_root/build/swift-module-cache"
bundled_tools="$repo_root/build/dependencies/bin"
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

if [[ ! -x "$bundled_tools/ffmpeg" || ! -x "$bundled_tools/ffprobe" ]]; then
  echo "Bundled FFmpeg tools are missing. Run ./scripts/build-ffmpeg-macos.sh first." >&2
  exit 1
fi

demucs_path="${MAKESTEM_DEMUCS_PATH:-$(command -v demucs || true)}"
if [[ -z "$demucs_path" || ! -x "$demucs_path" ]]; then
  echo "Demucs was not found. Set MAKESTEM_DEMUCS_PATH or install demucs-rs." >&2
  exit 1
fi

mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources/bin"
mkdir -p "$app/Contents/Resources/Licenses"
mkdir -p "$module_cache"
cp macos/Info.plist "$app/Contents/Info.plist"
cp target/release/makestem "$app/Contents/Helpers/makestem"
cp "$demucs_path" "$app/Contents/Resources/bin/demucs"
cp "$bundled_tools/ffmpeg" "$app/Contents/Resources/bin/ffmpeg"
cp "$bundled_tools/ffprobe" "$app/Contents/Resources/bin/ffprobe"
cp THIRD_PARTY_NOTICES.md "$app/Contents/Resources/Third-Party Notices.md"
cp build/dependencies/licenses/* "$app/Contents/Resources/Licenses/"

swiftc \
  -parse-as-library \
  -target arm64-apple-macos14.0 \
  -sdk "$macos_sdk" \
  -module-cache-path "$module_cache" \
  macos/MakeStemApp.swift \
  -o "$app/Contents/MacOS/MakeStem" \
  -framework SwiftUI \
  -framework AppKit \
  -framework UniformTypeIdentifiers

codesign --force --sign - "$app/Contents/Helpers/makestem"
codesign --force --sign - "$app/Contents/Resources/bin/demucs"
codesign --force --sign - "$app/Contents/Resources/bin/ffmpeg"
codesign --force --sign - "$app/Contents/Resources/bin/ffprobe"
codesign --force --sign - "$app"
echo "Built $app"
