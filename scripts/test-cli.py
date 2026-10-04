#!/usr/bin/env python3
"""Isolated end-to-end CLI/daemon test; uses absent device UIDs and emits no audio."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

binary_dir = Path(sys.argv[1] if len(sys.argv) > 1 else '.build/out/Products/Debug').resolve()
cli, daemon = binary_dir / 'audioroute', binary_dir / 'audiorouted'
with tempfile.TemporaryDirectory(prefix='ar-cli-', dir='/tmp') as temp:
    root = Path(temp)
    env = dict(os.environ, AUDIOROUTE_STATE_DIR=str(root / 'state'), AUDIOROUTE_SOCKET=str(root / 'control.sock'))
    log = open(root / 'daemon.log', 'w+')
    process = None
    def call(*args, code=0):
        p = subprocess.run([str(cli), *args, '--json'], env=env, capture_output=True, text=True, timeout=20)
        assert p.returncode == code, (args, p.returncode, p.stdout, p.stderr)
        return json.loads(p.stdout)
    def start():
        global process
        process = subprocess.Popen([str(daemon)], env=env, stdout=log, stderr=log)
        for _ in range(100):
            if (root / 'control.sock').exists():
                try:
                    call('daemon', 'status')
                    return
                except (AssertionError, OSError):
                    pass
            if process.poll() is not None:
                log.seek(0)
                raise AssertionError(log.read())
            time.sleep(.05)
        raise AssertionError('Daemon startup timed out')
    try:
        call('status', code=3)
        assert call('daemon', 'start', '--dry-run')['result']['would_start']
        assert not (root / 'control.sock').exists()
        start()
        assert call('daemon', 'stop', '--dry-run')['result']['would_stop']
        assert call('daemon', 'status')['ok']
        competing_env = dict(env, AUDIOROUTE_STATE_DIR=str(root / 'competing-state'))
        competing = subprocess.run([str(daemon)], env=competing_env, capture_output=True, text=True, timeout=10)
        assert competing.returncode != 0 and 'E_DAEMON_RUNNING' in competing.stderr
        assert call('daemon', 'status')['ok']  # competing start did not unlink active socket
        assert call('devices', 'list')['ok']
        assert call('apps', 'playing')['ok']
        assert call('permissions')['ok']
        scenario = {'version': 1, 'scenario': {'id': 'integration'}, 'inputs': {'guitar': {'type': 'device_input', 'device': 'coreaudio:device:missing-input-test', 'channels': [1]}}, 'outputs': {
            'teacher': {'type': 'device_output', 'device': 'coreaudio:device:missing-teacher-test', 'channels': 2, 'mix': {'guitar': {'gain_db': -3}}},
            'listener': {'type': 'device_output', 'device': 'coreaudio:device:missing-listener-test', 'channels': 2, 'master_gain_db': 2, 'mix': {'guitar': {'gain_db': 3}}}}}
        source = root / 'test.json'
        source.write_text(json.dumps(scenario))
        assert call('scenario', 'validate', str(source))['result']['valid']
        assert not call('scenario', 'apply', str(source), '--dry-run')['result']['changed']
        assert not (root / 'state/scenarios.json').exists()
        assert call('scenario', 'apply', str(source))['result']['changed']
        assert not call('scenario', 'apply', str(source))['result']['changed']
        status = call('scenario', 'verify', 'integration', code=4)['result']
        assert status['state'] == 'degraded' and status['verification']['working'] is False
        assert call('level', 'set', 'scenario:integration', 'output:teacher', 'input:guitar', '--db', '-9')['ok']
        exported = call('scenario', 'export', 'integration')['result']
        assert exported['outputs']['teacher']['mix']['guitar']['gain_db'] == -9
        assert exported['outputs']['listener']['mix']['guitar']['gain_db'] == 3
        assert exported['outputs']['listener']['master_gain_db'] == 2
        invalid = root / 'bad.json'
        invalid.write_text('{"version":999}')
        call('scenario', 'apply', str(invalid), code=1)
        assert call('scenario', 'export', 'integration')['result'] == exported
        call('scenario', 'delete', 'integration', code=1)
        call('daemon', 'stop')
        process.wait(timeout=10)
        start()
        assert call('scenario', 'export', 'integration')['result'] == exported
        call('scenario', 'delete', 'integration', '--yes')
        assert call('scenario', 'list')['result'] == []
        call('daemon', 'stop')
        process.wait(timeout=10)
        call('daemon', 'start')
        assert call('daemon', 'status')['ok']
        call('daemon', 'stop')
        print('PASS CLI integration: discovery, dry run, apply, idempotency, levels, truthful degraded verification, rollback, deletion guard, restart persistence')
    finally:
        if process and process.poll() is None:
            process.terminate()
            process.wait(timeout=10)
        log.close()
