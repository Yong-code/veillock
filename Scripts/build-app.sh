#!/bin/zsh
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
project_dir="$(cd "$script_dir/.." && pwd)"
app_path="$project_dir/dist/VeilLock.app"

cd "$project_dir"
swift build -c release

mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$project_dir/.build/release/VeilLock" "$app_path/Contents/MacOS/VeilLock"
cp "$project_dir/Resources/Info.plist" "$app_path/Contents/Info.plist"
cp "$project_dir/Resources/VeilLock.icns" "$app_path/Contents/Resources/VeilLock.icns"

# Desktop File Provider folders can attach these two attributes to a newly
# created bundle. They make macOS reject an otherwise valid code signature.
# Remove only those known bundle-level attributes; never clear attributes
# recursively.
xattr -d com.apple.FinderInfo "$app_path" 2>/dev/null || true
xattr -d 'com.apple.fileprovider.fpfs#P' "$app_path" 2>/dev/null || true

codesign --force --sign - "$app_path"
codesign --verify --deep --strict "$app_path"

printf 'Built %s\n' "$app_path"
