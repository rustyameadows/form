#!/bin/bash
# Reproducible standalone Cycles engine. Never installs or replaces a running LAB.
set -euo pipefail
cd "$(dirname "$0")/.."
repo="$PWD"
base="$repo/.local/cycles"
source="$base/source"
build="$base/build"
prefix="$repo/.local/engines/cycles-3eb35f85996b"
assert_engine_idle() {
  for binary in "$prefix/lab-cycles-render" "$prefix"/lib/*.dylib; do
    if [ -f "$binary" ] && lsof -t "$binary" >/dev/null 2>&1; then
      echo "A Cycles render is using $prefix; finish or cancel it before reinstalling." >&2
      exit 1
    fi
  done
}
assert_engine_idle
lock="$repo/Native/LabCycles/engine-lock.json"
commit="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["source_commit"])' "$lock")"
deps="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["dependency_commit"])' "$lock")"
mkdir -p "$base"
if [ ! -d "$source/.git" ]; then
  git clone --no-checkout https://github.com/blender/cycles.git "$source"
fi
if ! git -C "$source" cat-file -e "$commit^{commit}" 2>/dev/null; then
  git -C "$source" fetch --depth 1 origin "$commit"
fi
if [ "$(git -C "$source" rev-parse HEAD)" != "$commit" ]; then
  git -C "$source" checkout --detach "$commit"
fi
git -C "$source" -c submodule.lib/macos_arm64.update=checkout submodule update --init --depth 1 lib/macos_arm64
[ "$(git -C "$source/lib/macos_arm64" rev-parse HEAD)" = "$deps" ] || { echo "Unexpected Cycles dependency revision" >&2; exit 1; }
git -C "$source/lib/macos_arm64" lfs pull
python3 - "$source/CMakeLists.txt" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1]); text=p.read_text()
marker='\n# LAB integration: adds the private helper, without modifying engine behavior.\n'
if marker not in text:
    p.write_text(text+marker+'if(LAB_CYCLES_HELPER_SOURCE)\n  add_subdirectory("${LAB_CYCLES_HELPER_SOURCE}" lab-helper)\nendif()\n')
PY
cmake="${LAB_CMAKE:-$repo/.local/cad-kernel/tools/bin/cmake}"
ninja="${LAB_NINJA:-$repo/.local/cad-kernel/tools/bin/ninja}"
if [ ! -x "$cmake" ]; then cmake="$(command -v cmake)"; fi
if [ ! -x "$ninja" ]; then ninja="$(command -v ninja)"; fi
sdk_headers="$(xcrun --show-sdk-path)/usr/include/c++/v1"
if [ -f "$sdk_headers/type_traits" ]; then export CPLUS_INCLUDE_PATH="$sdk_headers${CPLUS_INCLUDE_PATH:+:$CPLUS_INCLUDE_PATH}"; fi
"$cmake" -S "$source" -B "$build" -G Ninja \
  -DCMAKE_MAKE_PROGRAM="$ninja" -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 -DWITH_STRICT_BUILD_OPTIONS=ON \
  -DWITH_CYCLES_DEVICE_METAL=ON -DWITH_CYCLES_EMBREE=ON \
  -DWITH_CYCLES_OPENIMAGEDENOISE=ON -DWITH_CYCLES_OPENSUBDIV=ON \
  -DWITH_CYCLES_STANDALONE_GUI=OFF -DWITH_CYCLES_HYDRA_RENDER_DELEGATE=OFF \
  -DWITH_CYCLES_USD=OFF -DWITH_CYCLES_OSL=OFF -DWITH_CYCLES_ALEMBIC=OFF \
  -DWITH_CYCLES_OPENVDB=OFF -DWITH_CYCLES_NANOVDB=OFF \
  -DLAB_CYCLES_HELPER_SOURCE="$repo/Native/LabCycles"
"$cmake" --build "$build" --parallel "${LAB_CYCLES_JOBS:-8}"
assert_engine_idle
"$cmake" --install "$build"
python3 "$repo/scripts/package-cycles.py" --record "$prefix"
printf '\nBuilt pinned Cycles engine: %s\n' "$prefix"
