#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ ! -x build/FORM.app/Contents/MacOS/FORM ]; then bash scripts/build.sh; fi
open build/FORM.app
