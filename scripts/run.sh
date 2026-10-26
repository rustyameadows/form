#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ ! -x build/LAB.app/Contents/MacOS/LAB ]; then bash scripts/build.sh; fi
open build/LAB.app
