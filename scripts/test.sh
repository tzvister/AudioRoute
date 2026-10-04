#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
swift test --disable-sandbox
scripts/test-driver.sh
scripts/test-realtime.sh
binary_dir="$(swift build --show-bin-path --disable-sandbox)"
python3 scripts/test-help.py "$binary_dir/audioroute"
python3 scripts/test-setup.py "$binary_dir/audioroute"
python3 scripts/test-cli.py "$binary_dir"
