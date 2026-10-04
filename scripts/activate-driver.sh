#!/bin/bash
# Explicit opt-in: restarting Core Audio interrupts existing audio sessions.
set -euo pipefail
if [[ "${1:-}" != --yes || "$#" != 1 ]]; then
  echo "Usage: sudo $0 --yes (acknowledges interruption of current audio sessions)" >&2
  exit 2
fi
if [[ "$EUID" != 0 ]]; then echo "Run with sudo to activate the installed driver." >&2; exit 1; fi
if [[ ! -f /Library/LaunchDaemons/org.audioroute.transport.plist ]]; then echo "Install the driver first." >&2; exit 1; fi
if ! /bin/launchctl print system/org.audioroute.transport >/dev/null 2>&1; then
  /bin/launchctl bootstrap system /Library/LaunchDaemons/org.audioroute.transport.plist
fi
/bin/launchctl kickstart -k system/org.audioroute.transport
if ! /bin/launchctl kickstart -k system/com.apple.audio.coreaudiod; then
  # SIP protects launchctl manipulation of some Apple services. Terminating
  # this audio process is permitted for administrators; launchd respawns it.
  # Never alter SIP or system launch-service protection.
  /usr/bin/killall coreaudiod
fi
echo "AudioRoute broker activated and Core Audio restarted."
