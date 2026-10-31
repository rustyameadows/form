#!/bin/bash
# Reopen the isolated Object Views demo without touching the main LAB library.
set -euo pipefail
cd "$(dirname "$0")/.."
app="$PWD/build/LAB-object-views-stable.app"
if [ ! -x "$app/Contents/MacOS/LAB" ]; then
  echo "The demo app bundle is missing: $app" >&2
  echo "Build the worktree with scripts/build.sh and package a demo bundle first." >&2
  exit 1
fi
open --env "LAB_LIBRARY_PATH=$PWD/.local/ObjectViewStableDemo" \
  --env "LAB_SOCKET_PATH=/private/tmp/lab-object-views-stable.sock" "$app"
