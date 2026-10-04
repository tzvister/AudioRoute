#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
output="${1:-$project_root/build/AudioRoute.driver}"
mkdir -p "$output/Contents/MacOS" "$output/Contents/Resources"
xcrun clang -std=c11 -O2 -Wall -Wextra -Wno-unused-parameter -fblocks -mmacosx-version-min=14.2 \
  -arch arm64 -arch x86_64 -bundle -framework CoreAudio -framework CoreFoundation \
  -I "$project_root/Sources/VirtualAudioTransport/include" \
  "$project_root/Driver/AudioRouteDriver.c" "$project_root/Sources/VirtualAudioTransport/VirtualAudioTransport.c" \
  -o "$output/Contents/MacOS/AudioRoute"
xcrun clang -std=c11 -O2 -Wall -Wextra -fblocks -mmacosx-version-min=14.2 -arch arm64 -arch x86_64 \
  -framework CoreFoundation -I "$project_root/Sources/VirtualAudioTransport/include" \
  "$project_root/Driver/TransportBroker.c" "$project_root/Sources/VirtualAudioTransport/VirtualAudioTransport.c" \
  -o "$output/Contents/Resources/AudioRouteTransportBroker"
/usr/bin/codesign --force --sign "${AUDIOROUTE_SIGN_IDENTITY:--}" "$output/Contents/Resources/AudioRouteTransportBroker"
cp "$project_root/Driver/Info.plist" "$output/Contents/Info.plist"
/usr/bin/codesign --force --sign "${AUDIOROUTE_SIGN_IDENTITY:--}" "$output"
/usr/bin/codesign --verify --strict "$output"
echo "$output"
