#!/bin/bash
set -euo pipefail
package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cache_dir="${NSKIT_CACHE_DIR:-${TMPDIR:-/tmp}/ninestems-kit-cache}"
mkdir -p "$cache_dir/clang" "$cache_dir/swift"
export CLANG_MODULE_CACHE_PATH="$cache_dir/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$cache_dir/swift"
# This package has no third-party plugins or dependencies. --disable-sandbox avoids nested sandbox failures in CLI workers.
swift build --disable-sandbox --package-path "$package_dir"
swift test --disable-sandbox --package-path "$package_dir"
