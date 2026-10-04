#!/usr/bin/env python3
"""Exercise installer upgrade guards in temporary folders, without root or service changes."""
import grp
import os
from pathlib import Path
import subprocess
import tempfile

project = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='audioroute-install-test-') as folder:
    root = Path(folder)
    shared = root / 'AudioRoute'
    devices = shared / 'devices'
    devices.mkdir(parents=True)
    state = shared / 'registry.plist'
    state.write_bytes(b'existing-user-state')
    group = grp.getgrgid(shared.stat().st_gid).gr_name
    launchctl = root / 'launchctl'
    launchctl.write_text('#!/bin/bash\n[[ "$1" == print ]] || exit 99\n')
    launchctl.chmod(0o700)
    scripts = {}
    for name in ('preinstall', 'postinstall'):
        text = (project / 'packaging/scripts' / name).read_text()
        # Adapt only environment/privilege boundaries. The permission checks,
        # stat formats, octal arithmetic and refusal branches run unchanged.
        text = text.replace('"$EUID" == 0', '"$EUID" == "$UID"')
        text = text.replace('/dev/console', str(root))
        text = text.replace('/Library/Application Support/AudioRoute', str(shared))
        text = text.replace('_coreaudiod', group)
        text = text.replace('/bin/launchctl', str(launchctl))
        script = root / name
        script.write_text(text)
        scripts[name] = script

    def run(name, succeeds, message=None):
        before = state.read_bytes(), state.stat().st_mode, shared.stat().st_mode, devices.stat().st_mode
        result = subprocess.run(['/bin/bash', str(scripts[name]), 'package', '/', '/'], capture_output=True, text=True)
        assert (result.returncode == 0) == succeeds, (name, result.returncode, result.stdout, result.stderr)
        if message:
            assert message in result.stderr, (name, result.stderr)
        after = state.read_bytes(), state.stat().st_mode, shared.stat().st_mode, devices.stat().st_mode
        assert after == before, 'Upgrade guard altered existing state or permissions'

    for path in (shared, devices):
        path.chmod(0o2750)
    # This reproduces the original bug: %Lp reports 750 even with setgid set.
    assert subprocess.check_output(['/usr/bin/stat', '-f', '%Lp', str(shared)], text=True).strip() == '750'
    for name in scripts:
        run(name, True)
        for path in (shared, devices):
            for mode in (0o750, 0o2770, 0o4750):
                path.chmod(mode)
                run(name, False, 'permissions need repair')
                path.chmod(0o2750)
        link = devices / 'unsafe-link'
        link.symlink_to(state)
        run(name, False, 'symbolic link')
        link.unlink()
print('PASS installer upgrade guards: valid setgid folders accepted, unsafe modes/links refused, saved state preserved; no installation or service changes')
