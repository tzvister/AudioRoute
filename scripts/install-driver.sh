#!/bin/bash
# Run explicitly after reviewing the build. Does not restart audio services automatically.
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
bundle="${1:-$project_root/build/AudioRoute.driver}"
if [[ "$EUID" != 0 ]]; then
  echo "Installation needs administrator access: sudo $0 '$bundle'" >&2
  exit 1
fi
if [[ ! -f "$bundle/Contents/MacOS/AudioRoute" ]]; then echo "Build the driver first." >&2; exit 1; fi
/usr/bin/codesign --verify --strict "$bundle"
owner="${SUDO_USER:-$(/usr/bin/stat -f '%Su' /dev/console)}"
if [[ "$owner" == root || "$owner" == loginwindow ]]; then echo "Install from the intended user's shell with sudo." >&2; exit 1; fi
/usr/bin/install -d -m 2750 -o "$owner" -g _coreaudiod "/Library/Application Support/AudioRoute" "/Library/Application Support/AudioRoute/devices"
if [[ -f "/Library/Application Support/AudioRoute/registry.plist" ]]; then
  /usr/sbin/chown "$owner":_coreaudiod "/Library/Application Support/AudioRoute/registry.plist"
  /bin/chmod 640 "/Library/Application Support/AudioRoute/registry.plist"
fi
/usr/bin/ditto "$bundle" /Library/Audio/Plug-Ins/HAL/AudioRoute.driver
/usr/sbin/chown -R root:wheel /Library/Audio/Plug-Ins/HAL/AudioRoute.driver
/bin/chmod -R go-w /Library/Audio/Plug-Ins/HAL/AudioRoute.driver
/usr/bin/install -m 644 -o root -g wheel "$project_root/Driver/org.audioroute.transport.plist" /Library/LaunchDaemons/org.audioroute.transport.plist
echo "Installed AudioRoute.driver and its system transport broker. Restart your Mac to load it; existing audio sessions may be interrupted."
