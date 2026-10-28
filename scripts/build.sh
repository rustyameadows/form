#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-debug}"
case "$configuration" in debug|release) ;; *) echo "Usage: scripts/build.sh [debug|release]" >&2; exit 1;; esac
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
app_path="${LAB_BUILD_APP_PATH:-$PWD/build/LAB.app}"
legacy_path="$PWD/build/FORM.app"
# Never replace a live executable. Custom candidate builds leave the installed app alone.
for target in "$app_path/Contents/MacOS/LAB"; do
  if [ -f "$target" ] && lsof -t "$target" >/dev/null 2>&1; then
    echo "Quit LAB before replacing $app_path, or set LAB_BUILD_APP_PATH to a candidate path." >&2; exit 1
  fi
done
if [ -z "${LAB_BUILD_APP_PATH:-}" ] && [ -d "$legacy_path" ] && [ ! -L "$legacy_path" ] && lsof -t "$legacy_path/Contents/MacOS/FORM" >/dev/null 2>&1; then
  echo "Quit FORM before installing LAB, or set LAB_BUILD_APP_PATH to a candidate path." >&2; exit 1
fi
swift build --disable-sandbox --cache-path "$PWD/.build/cache" --config-path "$PWD/.build/config" --security-path "$PWD/.build/security" -c "$configuration"
binary_path="$(swift build --disable-sandbox --cache-path "$PWD/.build/cache" --config-path "$PWD/.build/config" --security-path "$PWD/.build/security" -c "$configuration" --show-bin-path)"
mkdir -p "$(dirname "$app_path")"
stage="$(mktemp -d "$(dirname "$app_path")/.lab-package.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
bundle="$stage/LAB.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources/ThirdPartyNotices"
cp "$binary_path/Form" "$bundle/Contents/MacOS/LAB"
ln -s LAB "$bundle/Contents/MacOS/FORM"
cp "$binary_path/form-mcp" "$bundle/Contents/MacOS/lab-mcp"
cp "$binary_path/form-mcp" "$bundle/Contents/MacOS/form-mcp"
cp Resources/Info.plist "$bundle/Contents/Info.plist"
cp Sources/CFormClipper/LICENSE "$bundle/Contents/Resources/ThirdPartyNotices/Clipper2-Boost-1.0.txt"
cp Sources/CFormMesher/LICENSE "$bundle/Contents/Resources/ThirdPartyNotices/Earcut-ISC.txt"
swift Resources/Icon.swift "$stage/LAB.iconset"
iconutil -c icns "$stage/LAB.iconset" -o "$bundle/Contents/Resources/LAB.icns"
codesign --force --deep --sign - "$bundle"
codesign --verify --deep --strict "$bundle"
# Recheck after compilation/signing: the app could have opened during the build.
for target in "$app_path/Contents/MacOS/LAB"; do
  if [ -f "$target" ] && lsof -t "$target" >/dev/null 2>&1; then echo "LAB opened during the build. Quit it and rebuild." >&2; exit 1; fi
done
if [ -z "${LAB_BUILD_APP_PATH:-}" ]; then
  if [ -L "$legacy_path" ] && [ "$(readlink "$legacy_path")" != "LAB.app" ]; then echo "Unrecognized FORM.app symlink; leaving installed apps intact." >&2; exit 1; fi
  if [ -d "$legacy_path" ] && [ ! -L "$legacy_path" ] && lsof -t "$legacy_path/Contents/MacOS/FORM" >/dev/null 2>&1; then echo "FORM opened during the build. Quit it and rebuild." >&2; exit 1; fi
fi
# Backups keep the previous accepted bundle recoverable.
if [ -e "$app_path" ] || [ -L "$app_path" ]; then mv "$app_path" "$app_path.previous-$(date +%Y%m%d-%H%M%S)"; fi
mv "$bundle" "$app_path"
if [ -z "${LAB_BUILD_APP_PATH:-}" ]; then
  if [ -e "$legacy_path" ] && [ ! -L "$legacy_path" ]; then mv "$legacy_path" "$legacy_path.pre-LAB-$(date +%Y%m%d-%H%M%S)"; fi
  if [ -L "$legacy_path" ]; then
    [ "$(readlink "$legacy_path")" = "LAB.app" ] || { echo "Unrecognized FORM.app symlink; leaving it intact." >&2; exit 1; }
  else ln -s LAB.app "$legacy_path"; fi
fi
printf '\nBuilt %s\n' "$app_path"
