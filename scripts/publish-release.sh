#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
release_script="$repo_root/scripts/release-macos.sh"
sparkle_tools="$repo_root/build/xcode-derived/SourcePackages/artifacts/sparkle/Sparkle/bin"

fail() {
  echo "Publish failed: $1" >&2
  exit 1
}

cd "$repo_root"
command -v gh >/dev/null || fail "Install GitHub CLI from https://cli.github.com/."
gh auth status >/dev/null 2>&1 || fail "Run 'gh auth login' and try again."
[[ -z "$(git status --short)" ]] || fail "Commit or stash repository changes first."
upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)" \
  || fail "Set an upstream branch and push it before publishing."
[[ "$(git rev-parse HEAD)" == "$(git rev-parse "$upstream")" ]] \
  || fail "Push the current commit before publishing."

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' macos/Info.plist)"
tag="v$version"
notes="$(mktemp "${TMPDIR:-/tmp}/makestem-notes.XXXXXX")"
stage="$(mktemp -d "${TMPDIR:-/tmp}/makestem-appcast.XXXXXX")"
trap 'rm -f "$notes"; rm -rf "$stage"' EXIT

awk -v version="$version" '
  $0 ~ "^## " version "([[:space:]]|$)" { found = 1; next }
  found && /^## / { exit }
  found { print }
' CHANGELOG.md > "$notes"
[[ -s "$notes" ]] || fail "Add release notes for $version to CHANGELOG.md."
gh release view "$tag" >/dev/null 2>&1 && fail "GitHub release $tag already exists."

"$release_script" --notarize
dmg="$repo_root/dist/Makestem-$version.dmg"
checksum="$dmg.sha256"
[[ -f "$dmg" && -f "$checksum" ]] || fail "Release artifacts were not created."
[[ -x "$sparkle_tools/generate_appcast" ]] || fail "Sparkle tools were not resolved by Xcode."

cp "$dmg" "$stage/"
cp "$notes" "$stage/Makestem-$version.md"
"$sparkle_tools/generate_appcast" \
  --maximum-versions 1 \
  --maximum-deltas 0 \
  --download-url-prefix "https://github.com/sbone/makestem/releases/download/$tag/" \
  --link "https://github.com/sbone/makestem/releases/tag/$tag" \
  --embed-release-notes \
  -o "$stage/appcast.xml" \
  "$stage"

gh release create "$tag" \
  "$dmg" \
  "$checksum" \
  "$stage/appcast.xml" \
  --title "Makestem $version" \
  --notes-file "$notes" \
  --target "$(git branch --show-current)"

echo "Published https://github.com/sbone/makestem/releases/tag/$tag"
