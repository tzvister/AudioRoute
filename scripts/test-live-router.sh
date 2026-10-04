#!/bin/bash
# Requires installed/activated AudioRoute HAL and an already running daemon.
# Routes known PCM exclusively through temporary virtual devices. No physical
# devices are opened, defaults changed, or microphone permissions requested.
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cli="${1:-$project_root/build/audioroute}"
work="$(mktemp -d /tmp/audioroute-router-live.XXXXXX)"
source_id="audioroute-router-source-$$"
sink_a="audioroute-router-sink-a-$$"
sink_b="audioroute-router-sink-b-$$"
scenario="audioroute-router-live-$$"
created_source=false
created_a=false
created_b=false
applied=false
client_pid=""
cleanup() {
  if [ -n "$client_pid" ] && kill -0 "$client_pid" 2>/dev/null; then kill "$client_pid" || true; wait "$client_pid" || true; fi
  if "$applied"; then "$cli" scenario delete "$scenario" --yes --json || true; fi
  if "$created_b"; then "$cli" virtual delete "$sink_b" --yes --json || true; fi
  if "$created_a"; then "$cli" virtual delete "$sink_a" --yes --json || true; fi
  if "$created_source"; then "$cli" virtual delete "$source_id" --yes --json || true; fi
  rm -rf "$work"
}
trap cleanup EXIT
wait_stage() {
  local wanted="$1"
  for attempt in $(seq 1 200); do
    if [ -f "$work/ready" ] && [ "$(cat "$work/ready")" = "$wanted" ]; then return 0; fi
    if ! kill -0 "$client_pid" 2>/dev/null; then cat "$work/report.json" 2>/dev/null || true; wait "$client_pid"; return 1; fi
    sleep 0.1
  done
  echo "Timed out waiting for live router stage $wanted" >&2
  return 1
}
xcrun clang -std=c11 -O2 -Wall -Wextra -Wno-unused-parameter -framework CoreAudio -framework CoreFoundation \
  "$project_root/Tests/AudioRouteEngineLive/LiveRouterTests.c" -o "$work/live-router"
"$cli" daemon status --json
"$cli" virtual create "$source_id" --input 0 --output 2 --json
created_source=true
"$cli" virtual create "$sink_a" --input 2 --output 0 --json
created_a=true
"$cli" virtual create "$sink_b" --input 2 --output 0 --json
created_b=true
cat > "$work/scenario.json" <<JSON
{"version":1,"scenario":{"id":"$scenario","name":"Temporary isolated live router test","target_sample_rate":48000},"inputs":{"source":{"type":"virtual_output","device":"virtual:$source_id","channels":[1,2]}},"outputs":{"a":{"type":"virtual_input","virtual_device":"$sink_a","channels":2,"master_gain_db":0,"mix":{"source":{"gain_db":0,"map":"stereo"}}},"b":{"type":"virtual_input","virtual_device":"$sink_b","channels":2,"master_gain_db":6.020599913279624,"mix":{"source":{"gain_db":0,"map":"stereo"}}}},"policy":{"reconnect":true,"clip_protection":false}}
JSON
"$cli" scenario apply "$work/scenario.json" --json
applied=true
"$work/live-router" "$source_id" "$sink_a" "$sink_b" "$work/ready" "$work/command" "$work/report.json" &
client_pid=$!
wait_stage 0
"$cli" status "$scenario" --json
"$cli" scenario verify "$scenario" --json > "$work/verification.json"
cat "$work/verification.json"
"$cli" level set "scenario:$scenario" output:a input:source --db -6.020599913279624 --json
printf '1\n' > "$work/command"
wait_stage 1
"$cli" level set "scenario:$scenario" output:b --master-db 0 --json
printf '2\n' > "$work/command"
wait_stage 2
wait "$client_pid"
client_pid=""
cat "$work/report.json"
