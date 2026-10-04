#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d /tmp/audioroute-driver.XXXXXX)"
trap 'rm -rf "$work"' EXIT
xcrun clang -std=c11 -O1 -g -fsanitize=address,undefined -Wall -Wextra -Wno-unused-parameter -fblocks \
  -D AR_DRIVER_TEST=1 -D "AR_SHARED_DIRECTORY=\"$work/registry\"" \
  -framework CoreAudio -framework CoreFoundation -I "$project_root/Sources/VirtualAudioTransport/include" \
  "$project_root/Driver/DriverTests.c" "$project_root/Sources/VirtualAudioTransport/VirtualAudioTransport.c" -o "$work/driver-tests"
"$work/driver-tests"
