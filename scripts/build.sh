#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-debug}"
case "$configuration" in debug|release) ;; *) echo "Usage: scripts/build.sh [debug|release]" >&2; exit 1;; esac
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
swift build --disable-sandbox --cache-path "$PWD/.build/cache" --config-path "$PWD/.build/config" --security-path "$PWD/.build/security" -c "$configuration"
binary_path="$(swift build --disable-sandbox --cache-path "$PWD/.build/cache" --config-path "$PWD/.build/config" --security-path "$PWD/.build/security" -c "$configuration" --show-bin-path)"
app_path="$PWD/build/FORM.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$binary_path/Form" "$app_path/Contents/MacOS/FORM"
cp "$binary_path/form-mcp" "$app_path/Contents/MacOS/form-mcp"
cp Resources/Info.plist "$app_path/Contents/Info.plist"
mkdir -p "$app_path/Contents/Resources/ThirdPartyNotices"
cp Sources/CFormClipper/LICENSE "$app_path/Contents/Resources/ThirdPartyNotices/Clipper2-Boost-1.0.txt"
if [ ! -f "$app_path/Contents/Resources/FORM.icns" ] || [ Resources/Icon.swift -nt "$app_path/Contents/Resources/FORM.icns" ]; then
    swift Resources/Icon.swift "$PWD/build/FORM.iconset"
    iconutil -c icns "$PWD/build/FORM.iconset" -o "$app_path/Contents/Resources/FORM.icns"
fi
codesign --force --deep --sign - "$app_path"
printf '\nBuilt %s\n' "$app_path"
