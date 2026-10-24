#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
destination="${1:-$PWD/.local/engines}"
version="2.4.2"
digest="e15e7bb1b66214ec6e96b169b388004179c4f5f705effcdaf8c80d4992ee0366"
mkdir -p "$destination"
image_path="$destination/OrcaSlicer-$version.dmg"
if [ ! -f "$image_path" ]; then
  curl --fail --location --retry 2 --output "$image_path" "https://github.com/OrcaSlicer/OrcaSlicer/releases/download/v$version/OrcaSlicer_Mac_universal_V$version.dmg"
fi
printf '%s  %s\n' "$digest" "$image_path" | shasum -a 256 -c -
if [ ! -x "$destination/OrcaSlicer.app/Contents/MacOS/OrcaSlicer" ]; then
  mount_path="$(mktemp -d "${TMPDIR:-/tmp}/form-orca.XXXXXX")"
  trap 'hdiutil detach "$mount_path" >/dev/null 2>&1 || true' EXIT
  hdiutil attach -readonly -nobrowse -mountpoint "$mount_path" "$image_path"
  ditto "$mount_path/OrcaSlicer.app" "$destination/OrcaSlicer.app"
fi
printf '\nVerified official OrcaSlicer %s at %s\nSelect this app in FORM → Studio Library → Filaments & 3D printing → Slicing engine.\n' "$version" "$destination/OrcaSlicer.app"
