#!/usr/bin/env python3
"""Inspect a removal package without executing its scripts."""
from pathlib import Path
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

package = Path(sys.argv[1]).resolve(strict=True)
project = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='audioroute-uninstaller-check-') as folder:
    expanded = Path(folder) / 'expanded'
    subprocess.run(['/usr/sbin/pkgutil', '--expand-full', str(package), str(expanded)], check=True)
    component = expanded / 'AudioRoute-remove.pkg'
    info = ET.parse(component / 'PackageInfo').getroot()
    assert info.attrib['identifier'] == 'org.audioroute.pkg.uninstaller'
    assert info.attrib['auth'] == 'root'
    payload = component / 'Payload'
    assert not payload.exists() or not list(payload.rglob('*')), 'Removal package must have no payload'
    distribution = ET.parse(expanded / 'Distribution').getroot()
    assert distribution.find('title').text == 'Uninstall AudioRoute'
    assert distribution.find('options').attrib['rootVolumeOnly'] == 'true'
    script = component / 'Scripts' / 'postinstall'
    assert script.read_bytes() == (project / 'packaging/uninstall-scripts/postinstall').read_bytes()
    assert script.stat().st_mode & 0o111
    subprocess.run(['/bin/bash', '-n', str(script)], check=True)
    for name in ('welcome.html', 'conclusion.html'):
        assert list((expanded / 'Resources').rglob(name)), name
print('PASS uninstaller package: root/startup-disk removal, no payload, exact tested script, clear removal pages; nothing uninstalled')
