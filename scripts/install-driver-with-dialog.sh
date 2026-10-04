#!/bin/bash
# Invoke explicitly to request administrator authentication through macOS.
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
bundle="${1:-$project_root/build/AudioRoute.driver}"
quote() { printf "'%s'" "${1//\'/\'\\\'\'}"; }
command="$(quote "$project_root/scripts/install-driver.sh") $(quote "$bundle")"
/usr/bin/osascript - "$command" <<'APPLESCRIPT'
on run arguments
    do shell script (item 1 of arguments) with administrator privileges
end run
APPLESCRIPT
