#!/bin/bash
# Requires installed/active HAL driver. Captures only the dedicated test app,
# whose audio goes exclusively to a temporary virtual output; no physical tone.
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cli="${1:-$project_root/build/audioroute}"
work="$(mktemp -d /tmp/audioroute-tap.XXXXXX)"
source="audioroute-tap-source-$$"
sink="audioroute-tap-sink-$$"
scenario="audioroute-tap-live-$$"
created_source=false
created_sink=false
created_scenario=false
cleanup() {
  if "$created_scenario"; then "$cli" scenario delete "$scenario" --yes --json || true; fi
  if [[ -f "$work/source.pid" ]]; then
    source_pid="$(cat "$work/source.pid")"
    if [[ "$source_pid" =~ ^[0-9]+$ ]]; then kill "$source_pid" 2>/dev/null || true; fi
  fi
  if "$created_source"; then "$cli" virtual delete "$source" --yes --json || true; fi
  if "$created_sink"; then "$cli" virtual delete "$sink" --yes --json || true; fi
  rm -rf "$work"
}
trap cleanup EXIT
"$cli" daemon start --json
helper="$work/AudioRouteTapSource.app"
mkdir -p "$helper/Contents/MacOS"
xcrun clang -O2 -Wall -Wextra -Wno-unused-parameter -framework AppKit -framework CoreAudio \
  "$project_root/Tests/AudioRouteTapLive/TapSource.m" -o "$helper/Contents/MacOS/AudioRouteTapSource"
cat > "$helper/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.audioroute.tests.tap-source</string>
<key>CFBundleName</key><string>AudioRoute Tap Test Source</string>
<key>CFBundleExecutable</key><string>AudioRouteTapSource</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
/usr/bin/codesign --force --sign - "$helper"
xcrun clang -O2 -Wall -Wextra -Wno-unused-parameter -framework CoreAudio -framework CoreFoundation \
  "$project_root/Tests/AudioRouteTapLive/TapConsumer.c" -o "$work/tap-consumer"
"$cli" virtual create "$source" --input 0 --output 2 --json
created_source=true
"$cli" virtual create "$sink" --input 2 --output 0 --json
created_sink=true
/usr/bin/open -n -a "$helper" --args "org.audioroute.virtual.$source" "$work/source.pid"
ready=false
for attempt in {1..50}; do
  "$cli" apps playing --json > "$work/apps.json"
  if /usr/bin/python3 -c 'import json,sys; a=json.load(open(sys.argv[1]));sys.exit(0 if any(x.get("bundle_id")=="org.audioroute.tests.tap-source" and x.get("audio_active") is True for x in a.get("result",[])) else 1)' "$work/apps.json"; then ready=true; break; fi
  sleep 0.2
done
if ! "$ready"; then echo "Test application did not register an active audio process." >&2; cat "$work/apps.json"; exit 1; fi
cat > "$work/scenario.yaml" <<SCENARIO
version: 1
scenario:
  id: $scenario
  name: Application Tap Live Test
  target_sample_rate: 48000
inputs:
  test-app:
    type: application_output
    application: app:org.audioroute.tests.tap-source
    channels: [1, 2]
    mute_original: false
outputs:
  send:
    type: virtual_input
    virtual_device: $sink
    channels: 2
    master_gain_db: 0
    mix:
      test-app:
        gain_db: 0
        map: stereo
policy:
  reconnect: true
  clip_protection: false
SCENARIO
created_scenario=true
"$cli" scenario apply "$work/scenario.yaml" --json
if ! "$work/tap-consumer" "org.audioroute.virtual.$sink"; then
  "$cli" status "$scenario" --json || true
  "$cli" doctor "$scenario" --json || true
  echo "Application tap produced no matching PCM. Inspect daemon System Audio Recording permission if tap callbacks are silent." >&2
  exit 1
fi
"$cli" status "$scenario" --json
