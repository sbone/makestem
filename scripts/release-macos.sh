#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
dist_dir="$repo_root/dist"
notarize=0
run_tests=1
notary_profile="${MAKESTEM_NOTARY_PROFILE:-MakeStem Notary}"

usage() {
  cat <<'EOF'
Usage: ./scripts/release-macos.sh [--notarize] [--skip-tests]

Creates a Developer ID-signed Makestem DMG in dist/.

  --notarize    Submit only the finished DMG to Apple, then staple its ticket
  --skip-tests  Skip the complete regression suite before building
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --notarize) notarize=1 ;;
    --skip-tests) run_tests=0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

fail() {
  echo "Release failed: $1" >&2
  exit 1
}

find_identity() {
  local configured="${MAKESTEM_SIGNING_IDENTITY:-}"
  if [[ -n "$configured" ]]; then
    printf '%s' "$configured"
    return
  fi

  local identities
  identities=("${(@f)$(security find-identity -v -p codesigning 2>/dev/null \
    | awk '/Developer ID Application:/ { print $2 }')}" )
  (( ${#identities[@]} == 1 )) || fail \
    "Expected one Developer ID Application identity. Set MAKESTEM_SIGNING_IDENTITY to its certificate hash."
  printf '%s' "$identities[1]"
}

cd "$repo_root"
[[ -f "$repo_root/artwork/MakestemIcon.png" ]] || fail \
  "The release icon is missing. Add artwork/MakestemIcon.png and run ./scripts/build-app-icon.sh."
identity="$(find_identity)"
[[ -n "$identity" && "$identity" != "-" ]] || fail "A Developer ID Application identity is required."

if (( run_tests )); then
  echo "==> Running complete regression suite"
  ./scripts/test-all.sh
fi

echo "==> Building Developer ID-signed app"
MAKESTEM_SIGNING_IDENTITY="$identity" ./scripts/build-mac-app.sh
app="$repo_root/build/Makestem.app"
./scripts/validate-mac-app.sh "$app"
codesign --verify --deep --strict --verbose=2 "$app"
signature_details="$(codesign -d --verbose=4 "$app" 2>&1)"
[[ "$signature_details" == *"Authority=Developer ID Application:"* ]] \
  || fail "The app is not signed with Developer ID Application."

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
[[ "$version" == <->.* ]] || fail "The app has an invalid release version."
mkdir -p "$dist_dir"
dmg="$dist_dir/Makestem-$version.dmg"

stage_root="$(mktemp -d "${TMPDIR:-/tmp}/makestem-release.XXXXXX")"
trap 'rm -rf "$stage_root"' EXIT
stage="$stage_root/Makestem"
mkdir -p "$stage"
ditto "$app" "$stage/Makestem.app"
ln -s /Applications "$stage/Applications"

echo "==> Creating signed DMG"
rm -f "$dmg"
rm -f "$dmg.sha256"
hdiutil create \
  -volname "Makestem $version" \
  -srcfolder "$stage" \
  -format UDZO \
  -ov \
  "$dmg" >/dev/null
codesign --force --sign "$identity" --timestamp "$dmg"
codesign --verify --verbose=2 "$dmg"

if (( notarize )); then
  echo "==> Submitting DMG to Apple notarization"
  submission="$(xcrun notarytool submit "$dmg" \
    --keychain-profile "$notary_profile" \
    --wait 2>&1)" || fail "Apple notarization could not be completed."
  print -r -- "$submission"
  [[ "$submission" == *"status: Accepted"* ]] \
    || fail "Apple did not accept the DMG. Run 'xcrun notarytool history --keychain-profile \"$notary_profile\"' for details."
  echo "==> Stapling notarization ticket"
  xcrun stapler staple "$dmg"
  xcrun stapler validate "$dmg"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
else
  echo "==> Skipping notarization (use --notarize for a distributable release)"
fi

checksum="$(shasum -a 256 "$dmg" | awk '{ print $1 }')"
printf '%s  %s\n' "$checksum" "${dmg:t}" > "$dmg.sha256"

echo "Created $dmg"
echo "Created $dmg.sha256"
