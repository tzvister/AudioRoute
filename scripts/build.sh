#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
swift build -c release --disable-sandbox
binary_dir="$(swift build -c release --show-bin-path --disable-sandbox)"
mkdir -p build/AudioRoute.app/Contents/MacOS
cp "$binary_dir/audiorouted" build/AudioRoute.app/Contents/MacOS/
cp "$binary_dir/audioroute" build/audioroute
cat > build/AudioRoute.app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.audioroute.daemon</string>
<key>CFBundleName</key><string>AudioRoute</string>
<key>CFBundleExecutable</key><string>audiorouted</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>14.2</string>
<key>NSMicrophoneUsageDescription</key><string>AudioRoute captures only the physical inputs selected in your audio routing scenarios.</string>
<key>NSAudioCaptureUsageDescription</key><string>AudioRoute captures only application audio selected in your audio routing scenarios.</string>
</dict></plist>
PLIST
codesign --force --sign "${AUDIOROUTE_SIGN_IDENTITY:--}" --identifier org.audioroute.daemon build/AudioRoute.app
scripts/build-driver.sh
printf 'Built CLI: %s/build/audioroute\n' "$PWD"
