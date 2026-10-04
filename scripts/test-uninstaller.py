#!/usr/bin/env python3
"""Exercise temporary uninstaller copies; never stop processes or remove host files."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

project = Path(__file__).resolve().parent.parent
source = (project / "packaging/uninstall-scripts/postinstall").read_text()
installed_names = ["usr/local/bin/audioroute", "Applications/AudioRoute.app",
                   "Library/Audio/Plug-Ins/HAL/AudioRoute.driver",
                   "Library/LaunchDaemons/org.audioroute.transport.plist"]

mock_source = r'''#!/usr/bin/env python3
import json, os, pathlib, shutil, sys
root = pathlib.Path(os.environ['UNINSTALL_FIXTURE']).resolve()
state_path = root / 'mock-state.json'
state = json.loads(state_path.read_text())
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
state['calls'].append([name] + args)
def finish(code=0, output=''):
    state_path.write_text(json.dumps(state))
    if output: print(output)
    sys.exit(code)
if name == 'pgrep':
    assert args == ['-x', 'audiorouted'], args
    if state['case'] == 'process-inspection-error': finish(2)
    finish(0 if state['daemon'] else 1, '424242' if state['daemon'] else '')
elif name == 'pkill':
    assert args == ['-TERM', '-x', 'audiorouted'], args
    if state['case'] == 'signal-failure': finish(2)
    if state['case'] != 'stubborn-daemon': state['daemon'] = False
    finish()
elif name == 'sleep':
    assert args == ['0.1'], args
    finish()
elif name == 'launchctl':
    assert args[1:] == ['system/org.audioroute.transport'], args
    if args[0] == 'print':
        if state['case'] == 'service-inspection-error': finish(1)
        finish(0 if state['service'] else 113)
    assert args[0] == 'bootout', args
    if state['case'] == 'service-stop-failure': finish(5)
    if state['case'] != 'service-remains-loaded': state['service'] = False
    finish()
elif name == 'pkgutil':
    assert args[1:] == ['org.audioroute.pkg.core'], args
    if args[0] == '--pkg-info': finish(0 if state['receipt'] else 1)
    assert args[0] == '--forget', args
    state['receipt'] = False
    finish()
elif name == 'rm':
    assert args[0] in ['-f', '-rf'] and len(args) == 2, args
    path = pathlib.Path(args[1])
    assert path.is_absolute() and path.is_relative_to(root / 'installed'), args
    assert str(path.relative_to(root / 'installed')) in state['allowed_files'], args
    if path.is_symlink() or path.is_file(): path.unlink()
    elif path.is_dir(): shutil.rmtree(path)
    finish()
else:
    raise AssertionError('Unexpected command ' + name)
'''

def exercise(case, expected_success, installed=True, service=True, daemon=True, receipt=True, target="/", administrator=True):
    with tempfile.TemporaryDirectory(prefix="audioroute-uninstall-test-") as folder:
        root = Path(folder).resolve()
        installed_root = root / "installed"
        mocks = root / "commands"
        mocks.mkdir()
        for name in ("pgrep", "pkill", "sleep", "launchctl", "pkgutil", "rm"):
            tool = mocks / name
            tool.write_text(mock_source)
            tool.chmod(0o700)
        for name in installed_names:
            path = installed_root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            if installed:
                if path.suffix in (".app", ".driver"):
                    path.mkdir()
                    (path / "marker").write_bytes(b"installed-bundle")
                else: path.write_bytes(b"installed-file")
        user_state = root / "user/Library/Application Support/AudioRoute/scenarios.json"
        shared_state = root / "Library/Application Support/AudioRoute/registry.plist"
        shared_transport = shared_state.parent / "devices/saved.shm"
        for path in (user_state, shared_state, shared_transport):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"saved-route-data-" + path.name.encode())
            path.chmod(0o640)
        snapshots = {path: (path.read_bytes(), path.stat().st_mode) for path in (user_state, shared_state, shared_transport)}
        state_path = root / "mock-state.json"
        state_path.write_text(json.dumps(dict(case=case, service=service, daemon=daemon, receipt=receipt, calls=[], allowed_files=installed_names)))
        # Only adapt boundaries in temporary copies. Production process matching,
        # TERM/wait, service refusal, deletion order and preservation run unchanged.
        text = source.replace('"$EUID" == 0', '"0" == 0' if administrator else '"501" == 0')
        assert text != source
        for name in installed_names:
            text = text.replace("/" + name, str(installed_root / name))
        for absolute in ("/usr/bin/pgrep", "/usr/bin/pkill", "/bin/sleep", "/bin/launchctl", "/usr/sbin/pkgutil", "/bin/rm"):
            assert absolute in text
            text = text.replace(absolute, str(mocks / Path(absolute).name))
        script = root / "postinstall"
        script.write_text(text)
        env = dict(os.environ, UNINSTALL_FIXTURE=str(root))
        result = subprocess.run(["/bin/bash", str(script), "package", "/", target], env=env, capture_output=True, text=True, timeout=20)
        assert (result.returncode == 0) == expected_success, (case, result.returncode, result.stdout, result.stderr)
        state = json.loads(state_path.read_text())
        for path, snapshot in snapshots.items():
            assert (path.read_bytes(), path.stat().st_mode) == snapshot, (case, "saved state altered", path)
        removals = [call for call in state["calls"] if call[0] == "rm"]
        if expected_success:
            assert len(removals) == 4, (case, removals)
            assert all(not (installed_root / name).exists() for name in installed_names)
            assert not state["service"] and not state["daemon"] and not state["receipt"], (case, state)
            if receipt: assert ["pkgutil", "--forget", "org.audioroute.pkg.core"] in state["calls"]
            if installed:
                # Repeat the same script against already-removed fixtures.
                again = subprocess.run(["/bin/bash", str(script), "package", "/", "/"], env=env, capture_output=True, text=True, timeout=20)
                assert again.returncode == 0, (case, again.stderr)
                for path, snapshot in snapshots.items(): assert (path.read_bytes(), path.stat().st_mode) == snapshot
        else:
            assert not removals, (case, "files removed before successful shutdown", state["calls"])
            assert all((installed_root / name).exists() for name in installed_names)
        return state["calls"]

exercise("normal", True)
exercise("not-installed", True, installed=False, service=False, daemon=False, receipt=False)
for case in ("stubborn-daemon", "signal-failure", "process-inspection-error", "service-stop-failure", "service-remains-loaded", "service-inspection-error"):
    calls = exercise(case, False)
    if case == "stubborn-daemon": assert sum(call[0] == "sleep" for call in calls) == 50
for case, target, admin in [("wrong-target", "/Volumes/Other", True), ("non-root", "/", False)]:
    assert not exercise(case, False, target=target, administrator=admin)
print("PASS uninstaller fixture tests: exact TERM shutdown, bounded refusal, broker stop, receipts, repeat/no-install, route state preservation; no host processes, services or files changed")
