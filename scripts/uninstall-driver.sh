#!/bin/bash
# Removes only AudioRoute's installed bundle/service; retains routing configuration.
set -euo pipefail
if [[ "${1:-}" != --yes || "$#" != 1 ]]; then echo "Usage: sudo $0 --yes" >&2; exit 2; fi
if [[ "$EUID" != 0 ]]; then echo "Run with sudo to uninstall the driver." >&2; exit 1; fi
if /bin/launchctl print system/org.audioroute.transport >/dev/null 2>&1; then
  /bin/launchctl bootout system/org.audioroute.transport
fi
/bin/rm -f /Library/LaunchDaemons/org.audioroute.transport.plist
/bin/rm -rf /Library/Audio/Plug-Ins/HAL/AudioRoute.driver
echo "Removed AudioRoute.driver and its broker. Configuration retained. Restart your Mac to unload the driver."
