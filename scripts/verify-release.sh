#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
source "$project_root/scripts/release-common.sh"
tag="${1:?Pass the release tag}"
validate_release_tag "$tag"
output="$(cd "${2:?Pass the distribution directory}" && pwd)"
version="${tag#v}"
version="${version%%-*}"
temporary="$(mktemp -d "${TMPDIR:-/tmp}/WatcherVerify.XXXXXX")"
mounted=false
cleanup() {
  if $mounted; then hdiutil detach "$temporary/mounted" >/dev/null || true; fi
  rm -rf "$temporary"
}
trap cleanup EXIT
cd "$output"
shasum -a 256 -c SHA256SUMS.txt
archive="CodexWatcher-$tag-universal"
codesign --verify --strict "$archive.dmg"
xcrun stapler validate "$archive.dmg"
hdiutil attach "$archive.dmg" -readonly -nobrowse -mountpoint "$temporary/mounted"
mounted=true
ditto -x -k "$archive.zip" "$temporary/unpacked"
verify_app() {
  local app="$1"
  codesign --verify --strict "$app"
  xcrun stapler validate "$app"
  spctl --assess --type execute --verbose=2 "$app"
  local actual_version architectures team
  actual_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
  [[ "$actual_version" == "$version" ]] || { echo 'Packaged version mismatch.' >&2; exit 1; }
  team="$(codesign -dv "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
  [[ "$team" == "${APPLE_TEAM_ID:?Pass the expected signing team}" ]] || { echo 'Packaged team mismatch.' >&2; exit 1; }
  architectures="$(lipo -archs "$app/Contents/MacOS/CodexWatcher")"
  for architecture in arm64 x86_64; do
    [[ " $architectures " == *" $architecture "* ]] || { echo "Missing $architecture" >&2; exit 1; }
  done
  python3 "$project_root/scripts/smoke-test-app.py" "$app"
}
[[ -L "$temporary/mounted/Applications" && "$(readlink "$temporary/mounted/Applications")" == /Applications ]]
verify_app "$temporary/mounted/CodexWatcher.app"
verify_app "$temporary/unpacked/CodexWatcher.app"
echo 'Final DMG and ZIP verification passed.'
