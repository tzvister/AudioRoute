#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work="$(mktemp -d /tmp/audioroute-rt.XXXXXX)"
trap 'rm -rf "$work"' EXIT
xcrun clang -std=c11 -O1 -g -fsanitize=address,undefined -framework CoreAudio \
  -I Sources/CAudioRT/include Tests/AudioRouteEngineRT/rt_harness.c \
  -o "$work/rt-tests"
"$work/rt-tests"
