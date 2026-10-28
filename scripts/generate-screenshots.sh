#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
preview_language="${2:-zh-Hans}"
case "$preview_language" in
  en) preview_locale=en_US ;;
  zh-Hans) preview_locale=zh_CN ;;
  *) echo 'Preview language must be en or zh-Hans.' >&2; exit 1 ;;
esac
preview_dir="$(mktemp -d "${TMPDIR:-/tmp}/WatcherDocs.XXXXXX")"
trap 'rm -rf "$preview_dir"' EXIT
preview_app="$preview_dir/DocumentationPreview.app"
mkdir -p "$preview_app/Contents/MacOS" "$preview_app/Contents/Resources"
cat > "$preview_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>DocumentationPreview</string>
<key>CFBundleIdentifier</key><string>org.ximatai.CodexWatcher.DocumentationPreview</string>
<key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
</dict></plist>
PLIST
xcrun actool "$project_root/CodexWatcher/Assets.xcassets" \
  --compile "$preview_app/Contents/Resources" --platform macosx \
  --minimum-deployment-target 14.0 --target-device mac --output-format human-readable-text
xcrun xcstringstool compile "$project_root/CodexWatcher/Localizable.xcstrings" \
  --output-directory "$preview_app/Contents/Resources"
sources=()
for source in "$project_root"/CodexWatcher/*.swift; do
  case "$source" in */MyApp.swift) continue ;; esac
  sources+=("$source")
done
xcrun swiftc -parse-as-library -swift-version 5 \
  "${sources[@]}" "$project_root/scripts/DocumentationPreview.swift" \
  -o "$preview_app/Contents/MacOS/DocumentationPreview"
"$preview_app/Contents/MacOS/DocumentationPreview" "${1:-$project_root/docs/images}" -AppleLanguages "($preview_language)" -AppleLocale "$preview_locale"
