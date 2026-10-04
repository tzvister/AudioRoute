#!/bin/bash
# Build universal release payloads without replacing a running development app.
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
if [[ "$#" -gt 1 || "${1:-}" == --* ]]; then
  echo "Usage: scripts/build-release.sh [OUTPUT_DIRECTORY]" >&2
  exit 2
fi
release_output="${1:-$project_root/build/release-artifacts}"
source_version="$(sed -n 's/.*current = "\([^"]*\)".*/\1/p' Sources/AudioRouteControl/Version.swift)"
release_version="${AUDIOROUTE_VERSION:-$source_version}"
if [[ ! "$release_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "AUDIOROUTE_VERSION must be MAJOR.MINOR.PATCH" >&2; exit 2
fi
if [[ "$release_version" != "$source_version" ]]; then
  echo "Release version $release_version does not match Sources/AudioRouteControl/Version.swift ($source_version). Bump it before tagging." >&2; exit 2
fi
export CLANG_MODULE_CACHE_PATH="$project_root/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$project_root/.build/module-cache"
for release_arch in arm64 x86_64; do
  swift build -c release --disable-sandbox --arch "$release_arch" --scratch-path "$project_root/.build/release-$release_arch"
done
arm_products="$(swift build -c release --disable-sandbox --arch arm64 --scratch-path "$project_root/.build/release-arm64" --show-bin-path)"
intel_products="$(swift build -c release --disable-sandbox --arch x86_64 --scratch-path "$project_root/.build/release-x86_64" --show-bin-path)"
mkdir -p "$release_output/AudioRoute.app/Contents/MacOS"
xcrun lipo -create "$arm_products/audioroute" "$intel_products/audioroute" -output "$release_output/audioroute"
xcrun lipo -create "$arm_products/audiorouted" "$intel_products/audiorouted" -output "$release_output/AudioRoute.app/Contents/MacOS/audiorouted"
cat > "$release_output/AudioRoute.app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.audioroute.daemon</string>
<key>CFBundleName</key><string>AudioRoute</string>
<key>CFBundleExecutable</key><string>audiorouted</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$release_version</string>
<key>CFBundleVersion</key><string>$release_version</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>14.2</string>
<key>NSMicrophoneUsageDescription</key><string>AudioRoute uses only microphones and audio inputs you select in a routing scenario.</string>
<key>NSAudioCaptureUsageDescription</key><string>AudioRoute captures application audio only when you choose application capture in a scenario.</string>
</dict></plist>
PLIST
# Packaging applies Developer ID signatures; build payloads remain local ad hoc.
codesign --force --sign - "$release_output/audioroute"
codesign --force --sign - --identifier org.audioroute.daemon "$release_output/AudioRoute.app"
AUDIOROUTE_SIGN_IDENTITY=- scripts/build-driver.sh "$release_output/AudioRoute.driver"
for release_binary in "$release_output/audioroute" "$release_output/AudioRoute.app/Contents/MacOS/audiorouted" "$release_output/AudioRoute.driver/Contents/MacOS/AudioRoute" "$release_output/AudioRoute.driver/Contents/Resources/AudioRouteTransportBroker"; do
  xcrun lipo -verify_arch arm64 "$release_binary"
  xcrun lipo -verify_arch x86_64 "$release_binary"
done
printf 'Universal payload ready: %s\n' "$release_output"
