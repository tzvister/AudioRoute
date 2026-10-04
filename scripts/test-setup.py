#!/usr/bin/env python3
"""Exercise read-only onboarding with an absent private daemon socket."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

cli = Path(sys.argv[1]).resolve(strict=True)
with tempfile.TemporaryDirectory(prefix="audioroute-setup-") as directory:
    root = Path(directory)
    env = dict(os.environ, AUDIOROUTE_STATE_DIR=str(root / "state"), AUDIOROUTE_SOCKET=str(root / "socket"))
    def run(*args, code=0):
        result = subprocess.run([str(cli), *args], env=env, capture_output=True, text=True, timeout=30)
        assert result.returncode == code, (args, result.stdout, result.stderr)
        assert not (root / "state").exists(), "setup created daemon state"
        assert not (root / "socket").exists(), "setup started a daemon"
        return result.stdout
    for args in [("setup", "--json"), ("--json", "setup")]:
        report = json.loads(run(*args))["result"]
        assert report["mode"] == "read_only"
        assert report["daemon_running"] is False
        assert report["audio_verified"] is False
        assert isinstance(report["installation_ready"], bool)
        assert report["checks"] and report["next_steps"]
    assert "AudioRoute" in run("setup")
    assert "--start" in run("setup", "--start", "--help")
    assert json.loads(run("setup", "--unsupported", code=2))["error"]["code"] == "E_USAGE"
print("PASS read-only setup, JSON flag placement, actionable output, no daemon/state mutation")
