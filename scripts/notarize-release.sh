#!/bin/bash
set -euo pipefail
umask 077
project_root="$(cd "$(dirname "$0")/.." && pwd)"
source "$project_root/scripts/release-common.sh"
tag="${1:?Usage: bash scripts/notarize-release.sh vVERSION OUTPUT_DIRECTORY}"
validate_release_tag "$tag"
output="$(cd "${2:?Pass the build output directory}" && pwd)"
app="$output/CodexWatcher.app"
[[ -d "$app" ]] || { echo 'Build CodexWatcher.app first.' >&2; exit 1; }
for name in MACOS_CERTIFICATE_P12_BASE64 MACOS_CERTIFICATE_PASSWORD APPLE_TEAM_ID NOTARY_KEY_P8_BASE64 NOTARY_KEY_ID NOTARY_ISSUER_ID; do
  [[ -n "${!name:-}" ]] || { printf 'Missing release secret: %s\n' "$name" >&2; exit 1; }
done
[[ "$APPLE_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || { echo 'Invalid Apple Team ID.' >&2; exit 1; }
signing_dir="$(mktemp -d "${TMPDIR:-/tmp}/WatcherSigning.XXXXXX")"
keychain="$signing_dir/release.keychain-db"
cleanup() {
  security delete-keychain "$keychain" >/dev/null 2>&1 || true
  rm -rf "$signing_dir"
}
trap cleanup EXIT
keychain_password="$(openssl rand -hex 24)"
printf '%s' "$MACOS_CERTIFICATE_P12_BASE64" | base64 --decode > "$signing_dir/certificate.p12"
printf '%s' "$NOTARY_KEY_P8_BASE64" | base64 --decode > "$signing_dir/notary.p8"
security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security import "$signing_dir/certificate.p12" -k "$keychain" -P "$MACOS_CERTIFICATE_PASSWORD" \
  -T /usr/bin/codesign -T /usr/bin/security >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain" >/dev/null
identities="$(security find-identity -v -p codesigning "$keychain" | awk '/"Developer ID Application:/ { print $2 }')"
identity_count="$(printf '%s\n' "$identities" | awk 'NF { count++ } END { print count+0 }')"
[[ "$identity_count" == 1 ]] || { echo 'The P12 must contain exactly one valid Developer ID Application identity and its private key.' >&2; exit 1; }
# The application has no bundled helper binaries or frameworks. Never use --deep
# to hide missing nested signatures if the bundle gains executable dependencies.
codesign --force --keychain "$keychain" --sign "$identities" --timestamp --options runtime "$app"
codesign --verify --strict --verbose=2 "$app"
actual_team="$(codesign -dv "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
[[ "$actual_team" == "$APPLE_TEAM_ID" ]] || { echo 'Signing identity belongs to a different Apple team.' >&2; exit 1; }

notarize() {
  local archive="$1"
  local result="$2"
  local submit_status=0
  xcrun notarytool submit "$archive" --key "$signing_dir/notary.p8" \
    --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" \
    --wait --timeout 30m --output-format json > "$result" || submit_status=$?
  python3 - "$result" "$submit_status" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as handle:
        result = json.load(handle)
except (OSError, ValueError):
    raise SystemExit('No valid notarization response; no release will be uploaded.')
print('Notarization:', result.get('id'), result.get('status'))
if sys.argv[2] != '0' or result.get('status') != 'Accepted':
    raise SystemExit('Apple did not accept this archive; no release will be uploaded.')
PY
}

ditto -c -k --keepParent "$app" "$signing_dir/submission.zip"
notarize "$signing_dir/submission.zip" "$output/app-notary-result.json"
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"

archive_name="CodexWatcher-${tag}-universal"
ditto -c -k --keepParent "$app" "$output/$archive_name.zip"
mkdir "$signing_dir/dmg"
ditto --norsrc "$app" "$signing_dir/dmg/CodexWatcher.app"
ln -s /Applications "$signing_dir/dmg/Applications"
hdiutil create -volname 'CodexWatcher' -srcfolder "$signing_dir/dmg" -ov -format UDZO "$output/$archive_name.dmg"
codesign --keychain "$keychain" --sign "$identities" --timestamp "$output/$archive_name.dmg"
notarize "$output/$archive_name.dmg" "$output/dmg-notary-result.json"
xcrun stapler staple "$output/$archive_name.dmg"
xcrun stapler validate "$output/$archive_name.dmg"
codesign --verify --strict "$output/$archive_name.dmg"
(
  cd "$output"
  shasum -a 256 "$archive_name.dmg" "$archive_name.zip" > SHA256SUMS.txt
)
echo 'Signed, notarized and stapled DMG/ZIP are ready for final package verification.'
