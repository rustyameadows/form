#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
lab_sdk_cpp_headers="$(xcrun --show-sdk-path)/usr/include/c++/v1"
if [ -f "$lab_sdk_cpp_headers/type_traits" ]; then
  export CPLUS_INCLUDE_PATH="$lab_sdk_cpp_headers${CPLUS_INCLUDE_PATH:+:$CPLUS_INCLUDE_PATH}"
fi
unset lab_sdk_cpp_headers
swift test --disable-sandbox --cache-path "$PWD/.build/cache" --config-path "$PWD/.build/config" --security-path "$PWD/.build/security"
