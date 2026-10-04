#!/bin/bash
# Requires prior explicit administrator installation + activation. Sends known
# PCM only through isolated virtual devices; never emits audio to physical output.
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cli="${1:-$project_root/build/audioroute}"
"$cli" daemon start --json
work="$(mktemp -d /tmp/audioroute-live.XXXXXX)"
mic="audioroute-live-mic-$$"
duplex="audioroute-live-duplex-$$"
created_mic=false
created_duplex=false
cleanup() {
  if "$created_mic"; then "$cli" virtual delete "$mic" --yes --json || true; fi
  if "$created_duplex"; then "$cli" virtual delete "$duplex" --yes --json || true; fi
  rm -rf "$work"
}
trap cleanup EXIT
xcrun clang -std=c11 -O2 -Wall -Wextra -Wno-unused-parameter -framework CoreAudio -framework CoreFoundation \
  -I "$project_root/Sources/VirtualAudioTransport/include" "$project_root/Driver/LiveDriverTests.c" \
  "$project_root/Sources/VirtualAudioTransport/VirtualAudioTransport.c" -o "$work/live-test"
"$cli" virtual create "$mic" --input 2 --output 0 --json
created_mic=true
"$work/live-test" "$mic" 0
"$cli" virtual create "$duplex" --input 2 --output 2 --json
created_duplex=true
"$work/live-test" "$duplex" 2
