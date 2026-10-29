#!/bin/bash
# Build the pinned exact-geometry dependency locally. No Homebrew/global install.
set -euo pipefail
cd "$(dirname "$0")/.."
base="$PWD/.local/cad-kernel"
prefix="$PWD/.local/engines/occt-8.0.1-form-gprop2"
occt_source="$base/OCCT-8_0_1-form-gprop2"
occt_build="$base/build-form-gprop2"
# Keep the accepted older prefix intact; never rewrite a prefix mapped by a
# native developer host, including a host opened while this build runs.
occt_assert_prefix_idle() {
  for occt_library in "$prefix"/lib/libTK*.dylib; do
    if [ -f "$occt_library" ] && lsof -t "$occt_library" >/dev/null 2>&1; then
      echo "OCCT prefix is loaded by a process; close that owned host before installing: $prefix" >&2
      exit 1
    fi
  done
}
occt_assert_prefix_idle
archive="$base/OCCT-V8_0_1.tar.gz"
expected="0d6913eae4bcc09a3653ceced6dda1aec11c35a1513d4c06762c9b002092c68a"
mkdir -p "$base" "$PWD/.local/engines"
if [ ! -f "$archive" ]; then
  curl --fail --location --retry 2 --output "$archive.download" https://github.com/Open-Cascade-SAS/OCCT/archive/refs/tags/V8_0_1.tar.gz
  mv "$archive.download" "$archive"
fi
actual="$(shasum -a 256 "$archive" | cut -d ' ' -f 1)"
[ "$actual" = "$expected" ] || { echo "OCCT source digest mismatch; refusing to build." >&2; exit 1; }
if [ ! -f "$occt_source/CMakeLists.txt" ]; then
  mkdir -p "$occt_source"
  tar -xzf "$archive" -C "$occt_source" --strip-components=1
fi
if [ ! -x "$base/tools/bin/cmake" ] || [ ! -x "$base/tools/bin/ninja" ]; then
  python3 -m venv "$base/tools"
  "$base/tools/bin/python" -m pip install --cache-dir "$base/pip-cache" cmake==3.31.6 ninja==1.11.1.4
fi
"$base/tools/bin/python" scripts/occt-patches.py apply "$occt_source"
occt_sdk_cpp_headers="$(xcrun --show-sdk-path)/usr/include/c++/v1"
if [ -f "$occt_sdk_cpp_headers/type_traits" ]; then
  export CPLUS_INCLUDE_PATH="$occt_sdk_cpp_headers${CPLUS_INCLUDE_PATH:+:$CPLUS_INCLUDE_PATH}"
fi
unset occt_sdk_cpp_headers
jobs="${LAB_CAD_BUILD_JOBS:-4}"
case "$jobs" in ''|*[!0-9]*) echo "LAB_CAD_BUILD_JOBS must be an integer." >&2; exit 1;; esac
[ "$jobs" -ge 1 ] && [ "$jobs" -le 32 ] || { echo "Use 1–32 build jobs." >&2; exit 1; }
"$base/tools/bin/cmake" -S "$occt_source" -B "$occt_build" -G Ninja \
 -DCMAKE_MAKE_PROGRAM="$base/tools/bin/ninja" -DCMAKE_BUILD_TYPE=Release \
 -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
 -DBUILD_LIBRARY_TYPE=Shared -DCMAKE_INSTALL_PREFIX="$prefix" \
 -DINSTALL_DIR_LIB=lib -DINSTALL_DIR_INCLUDE=include/opencascade \
 -DINSTALL_DIR_RESOURCE=share/opencascade/resources -DCMAKE_INSTALL_RPATH=@loader_path \
 -DBUILD_MODULE_FoundationClasses=OFF -DBUILD_MODULE_ModelingData=OFF \
 -DBUILD_MODULE_ModelingAlgorithms=OFF -DBUILD_MODULE_Visualization=OFF \
 -DBUILD_MODULE_ApplicationFramework=OFF -DBUILD_MODULE_DataExchange=OFF \
 -DBUILD_MODULE_Draw=OFF -DBUILD_ADDITIONAL_TOOLKITS='TKDESTEP;TKMesh;TKOffset;TKFillet;TKBool;TKPrim' \
 -DUSE_FREETYPE=OFF -DUSE_TBB=OFF -DUSE_OPENGL=OFF -DUSE_GLES2=OFF \
 -DUSE_TK=OFF -DUSE_RAPIDJSON=OFF -DUSE_DRACO=OFF -DUSE_VTK=OFF -DBUILD_DOC_Overview=OFF
"$base/tools/bin/cmake" --build "$occt_build" --parallel "$jobs"
occt_assert_prefix_idle
"$base/tools/bin/cmake" --install "$occt_build"
mkdir -p "$prefix/share/licenses/occt"
cp Sources/CFormCADKernel/LICENSE_LGPL_21.txt Sources/CFormCADKernel/OCCT_LGPL_EXCEPTION.txt Sources/CFormCADKernel/UPSTREAM.json "$prefix/share/licenses/occt/"
"$base/tools/bin/python" scripts/occt-patches.py record "$prefix" "$occt_source"
printf '\nOCCT 8.0.1 installed locally: %s\n' "$prefix"
