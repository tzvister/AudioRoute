#!/usr/bin/env python3
"""Inspect a built installer without installing or invoking its scripts."""
import pathlib, plistlib, subprocess, sys, tempfile, xml.etree.ElementTree as ET

package = pathlib.Path(sys.argv[1]).resolve(strict=True)
def run(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT)
with tempfile.TemporaryDirectory(prefix="audioroute-pkg-test-") as folder:
    expanded = pathlib.Path(folder) / "expanded"
    run("/usr/sbin/pkgutil", "--expand-full", str(package), str(expanded))
    component = expanded / "AudioRoute-core.pkg"
    payload = component / "Payload"
    info = ET.parse(component / "PackageInfo").getroot()
    assert info.attrib["auth"] == "root" and info.attrib["install-location"] == "/"
    assert info.attrib["relocatable"] == "false"
    distribution = ET.parse(expanded / "Distribution").getroot()
    assert distribution.find(".//os-version").attrib["min"] == "14.2"
    assert distribution.find("options").attrib["hostArchitectures"] == "arm64,x86_64"
    paths = ["usr/local/bin/audioroute", "Applications/AudioRoute.app/Contents/MacOS/audiorouted",
             "Library/Audio/Plug-Ins/HAL/AudioRoute.driver/Contents/MacOS/AudioRoute",
             "Library/Audio/Plug-Ins/HAL/AudioRoute.driver/Contents/Resources/AudioRouteTransportBroker"]
    for name in paths:
        binary = payload / name
        assert set(run("/usr/bin/lipo", "-archs", str(binary)).split()) == {"arm64", "x86_64"}
        targets = [line.split()[-1] for line in run("xcrun", "vtool", "-show-build", str(binary)).splitlines() if "minos " in line]
        assert len(targets) == 2 and all(value in {"14", "14.0", "14.2"} for value in targets), (name, targets)
    for name in [paths[0], "Applications/AudioRoute.app", "Library/Audio/Plug-Ins/HAL/AudioRoute.driver", paths[-1]]:
        run("/usr/bin/codesign", "--verify", "--strict", str(payload / name))
    for line in run("/usr/bin/lsbom", str(component / "Bom")).splitlines():
        fields = line.split("\t")
        assert fields[2] == "0/0", line
    for script in ["preinstall", "postinstall"]:
        path = component / "Scripts" / script
        run("/bin/bash", "-n", str(path))
        assert "killall" not in path.read_text() and "reboot" not in path.read_text()
    assert run(str(payload / paths[0]), "--version").strip() == "audioroute " + info.attrib["version"]
    for app in ["Applications/AudioRoute.app", "Library/Audio/Plug-Ins/HAL/AudioRoute.driver"]:
        meta = plistlib.loads((payload / app / "Contents/Info.plist").read_bytes())
        assert meta["CFBundleShortVersionString"] == info.attrib["version"]
print("PASS installer contents, fixed paths, universal slices, macOS targets, signatures, root ownership and scripts; no installation performed")
