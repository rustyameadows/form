#!/bin/bash
# Build a separate demo bundle, leaving the regular LAB app untouched.
set -euo pipefail
cd "$(dirname "$0")/.."
engine="${LAB_OCCT_ROOT:-$PWD/.local/engines/occt-8.0.1-form-gprop2}"
archive="$PWD/.local/cad-kernel/OCCT-V8_0_1.tar.gz"
if [ ! -f "$archive" ] && [ -n "${LAB_OCCT_ARCHIVE:-}" ]; then
  [ -f "$LAB_OCCT_ARCHIVE" ] || { echo "LAB_OCCT_ARCHIVE must name the pinned OCCT source archive." >&2; exit 1; }
  mkdir -p .local/cad-kernel
  ln -s "$LAB_OCCT_ARCHIVE" "$archive"
fi
if [ ! -f "$archive" ]; then
  echo "Install the pinned OCCT engine and source archive with scripts/install-occt.sh, or set LAB_OCCT_ROOT and LAB_OCCT_ARCHIVE." >&2
  exit 1
fi
app="$PWD/build/LAB-object-views-stable.app"
LAB_OCCT_ROOT="$engine" LAB_BUILD_APP_PATH="$app" bash scripts/build.sh
plutil -replace CFBundleIdentifier -string studio.form.objectviews.stable "$app/Contents/Info.plist"
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"
