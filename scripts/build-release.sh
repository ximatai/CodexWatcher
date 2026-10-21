#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
source "$project_root/scripts/release-common.sh"
tag="${1:?Usage: bash scripts/build-release.sh vVERSION OUTPUT_DIRECTORY}"
validate_release_tag "$tag"
version="${tag#v}"
version="${version%%-*}"
output="${2:?Pass an output directory}"
mkdir -p "$output"
output="$(cd "$output" && pwd)"
if [[ -e "$output/CodexWatcher.app" ]]; then
  echo 'Output already contains CodexWatcher.app; use a fresh directory.' >&2
  exit 1
fi
build_number="${GITHUB_RUN_NUMBER:-1}"
[[ "$build_number" =~ ^[0-9]+$ ]] || { echo 'Invalid build number.' >&2; exit 1; }
release_build="$(mktemp -d "${TMPDIR:-/tmp}/WatcherRelease.XXXXXX")"
trap 'rm -rf "$release_build"' EXIT
xcodebuild -project "$project_root/CodexWatcher.xcodeproj" -scheme CodexWatcher \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath "$release_build" \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO ENABLE_DEBUG_DYLIB=NO \
  CODE_SIGNING_ALLOWED=NO MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build_number" build
ditto --norsrc "$release_build/Build/Products/Release/CodexWatcher.app" "$output/CodexWatcher.app"
xattr -cr "$output/CodexWatcher.app"
architectures="$(lipo -archs "$output/CodexWatcher.app/Contents/MacOS/CodexWatcher")"
for architecture in arm64 x86_64; do
  case " $architectures " in
    *" $architecture "*) ;;
    *) echo "Missing release architecture: $architecture" >&2; exit 1 ;;
  esac
done
actual_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$output/CodexWatcher.app/Contents/Info.plist")"
[[ "$actual_version" == "$version" ]] || { echo 'Version mismatch.' >&2; exit 1; }
printf 'Built %s (arm64 + x86_64). Not yet signed or distributable.\n' "$tag"
