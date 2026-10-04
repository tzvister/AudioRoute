#!/usr/bin/env python3
"""Test the CLI's offline documentation contract without starting a real daemon.

Usage: scripts/test-help.py /absolute/path/to/audioroute
The executable is copied beside a launch-detection stub. Even a regression in
`daemon start --help` cannot start AudioRoute, open audio devices or modify the
normal user state. All requests use an absent private socket/state directory.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("executable", type=Path)
args = parser.parse_args()
source_cli = args.executable.expanduser().resolve(strict=True)
assert os.access(source_cli, os.X_OK), f"Not executable: {source_cli}"

required_commands = {
    "daemon start", "daemon stop", "daemon status",
    "devices list", "devices inspect", "apps list", "apps playing",
    "virtual list", "virtual create", "virtual inspect", "virtual delete",
    "scenario list", "scenario show", "scenario export", "scenario validate",
    "scenario apply", "scenario verify", "scenario delete", "level set",
    "status", "meter", "doctor", "inspect", "permissions",
}

with tempfile.TemporaryDirectory(prefix="ar-help-", dir="/tmp") as directory:
    root = Path(directory)
    cli = root / "audioroute"
    shutil.copy2(source_cli, cli)
    state = root / "state-must-not-be-created"
    socket = root / "missing-control.sock"
    launch_marker = root / "unexpected-daemon-launch"
    daemon = root / "audiorouted"
    daemon.write_text("#!/bin/sh\n: > \"$AUDIOROUTE_HELP_LAUNCH_MARKER\"\nexit 97\n")
    daemon.chmod(0o700)
    env = dict(os.environ, AUDIOROUTE_STATE_DIR=str(state),
               AUDIOROUTE_SOCKET=str(socket),
               AUDIOROUTE_HELP_LAUNCH_MARKER=str(launch_marker))
    checks = 0

    def no_side_effects():
        assert not state.exists(), "Documentation command created daemon state"
        assert not socket.exists(), "Documentation command created a daemon socket"
        assert not launch_marker.exists(), "Documentation command tried to launch a daemon"

    def call(*tokens, code=0):
        global checks
        no_side_effects()
        process = subprocess.run([str(cli), *tokens], env=env, capture_output=True,
                                 text=True, timeout=5)
        no_side_effects()
        assert process.returncode == code, (tokens, process.returncode,
                                             process.stdout, process.stderr)
        assert process.stdout.strip(), (tokens, "Empty documentation output")
        checks += 1
        return process.stdout

    def envelope(*tokens):
        value = json.loads(call(*tokens))
        assert value.get("protocol_version") == 1 and value.get("ok") is True, value
        assert "result" in value, value
        return value["result"]

    def command_records(result):
        assert isinstance(result, dict) and isinstance(result.get("commands"), list), result
        records = result["commands"]
        assert records, "Help omitted all command records"
        for record in records:
            assert isinstance(record, dict), record
            for field in ("name", "usage", "summary"):
                assert isinstance(record.get(field), str) and record[field].strip(), record
        names = [record["name"] for record in records]
        assert len(names) == len(set(names)), "Duplicate command names in help catalog"
        return records

    # Root help must remain available without IPC, including the machine catalog.
    top = call("--help")
    assert "audioroute" in top and "scenario" in top and "--json" in top, top
    assert call("help") == top
    assert call() == top
    catalog = envelope("help", "--json")
    assert catalog.get("name") == "audioroute" and catalog.get("version"), catalog
    records = command_records(catalog)
    assert required_commands <= {record["name"] for record in records}, catalog
    assert {"schema", "examples", "guide"} <= set(catalog.get("discovery", {})), catalog
    assert "exit_codes" in catalog, "Machine catalog omitted deterministic exit codes"
    assert envelope("--help", "--json") == catalog
    assert call("--version").strip() == "audioroute " + catalog["version"]
    assert envelope("--version", "--json")["version"] == catalog["version"]

    # Every documented command is discoverable through both topic forms.
    for name in sorted(required_commands):
        topic = name.split()
        flagged = call(*topic, "--help")
        requested = call("help", *topic)
        assert flagged == requested, (name, "Topic forms diverge")
        assert name in flagged, (name, flagged)
        details = envelope("help", *topic, "--json")
        assert details.get("topic") == name, details
        matching = command_records(details)
        assert name in {record["name"] for record in matching}, details

    virtual_group = envelope("help", "virtual", "--json")
    assert {r["name"] for r in command_records(virtual_group)} == {
        "virtual list", "virtual create", "virtual inspect", "virtual delete"
    }, virtual_group
    for name in ("schema", "examples", "guide"):
        assert name in call(name, "--help"), name

    # Help wins before parsing values, resolving files or taking any action.
    cases = [
        ("virtual", "create", "Name", "--help"),
        ("virtual", "create", "Name", "--input", "not-a-number", "--help"),
        ("virtual", "delete", "missing-device", "--yes", "--help"),
        ("scenario", "apply", "/definitely/absent/scenario.yaml", "--help"),
        ("scenario", "delete", "missing-scenario", "--yes", "--help"),
        ("level", "set", "scenario:missing", "output:missing", "--db", "bad", "--help"),
        ("daemon", "start", "--help"),
        ("daemon", "stop", "--help"),
    ]
    for tokens in cases:
        text = call(*tokens)
        assert " ".join(tokens[:2]) in text, (tokens, text)
        details = envelope(*tokens, "--json")
        assert details.get("topic") == " ".join(tokens[:2]), details

    # The JSON schema exposes scenario-centric routing and independent levels.
    schema = envelope("schema", "--json")
    assert isinstance(schema, dict) and schema.get("$schema", "").startswith("https://"), schema
    assert schema.get("type") == "object", schema
    properties = schema.get("properties", {})
    assert {"version", "scenario", "inputs", "outputs", "policy"} <= set(properties), schema
    assert {"version", "scenario", "inputs", "outputs"} <= set(schema.get("required", [])), schema
    encoded_schema = json.dumps(schema)
    for field in ("trim_db", "gain_db", "master_gain_db", "mix", "application_output",
                  "virtual_input", "mute_original", "consumer_application"):
        assert field in encoded_schema, f"Schema omitted {field}"
    assert envelope("schema") == schema

    listing = envelope("examples", "--json")
    names = listing.get("examples")
    assert isinstance(names, list) and names == sorted(set(names)), listing
    assert {"physical-route", "explicit-virtual-guitar-lesson"} <= set(names), listing
    plain_listing = call("examples")
    for name in names:
        assert name in plain_listing, plain_listing
        item = envelope("examples", name, "--json")
        assert item.get("name") == name and item.get("format") == "yaml", item
        yaml = item.get("content")
        assert isinstance(yaml, str) and yaml.startswith("version: 1"), item
        assert all(field in yaml for field in ("scenario:", "inputs:", "outputs:", "mix:")), item
        assert call("examples", name).rstrip() == yaml.rstrip(), (name, "Raw YAML differs from JSON content")

    guide = envelope("guide", "--json").get("guide")
    assert isinstance(guide, str) and len(guide) > 100, guide
    assert call("guide").rstrip() == guide.rstrip(), "Plain and JSON guides diverge"
    for operation in ("scenario", "validate", "apply", "verify", "devices", "--json"):
        assert operation in guide, f"Guide omitted {operation}"

    # Typos are usage errors with structured, actionable output rather than IPC.
    for tokens in [
        ("help", "not-a-command"), ("not-a-command", "--help"),
        ("help", "virtual", "not-a-subcommand"),
        ("virtual", "not-a-subcommand", "--help"),
        ("help", "daemon", "not-a-subcommand"),
        ("examples", "not-an-example"),
    ]:
        failure = json.loads(call(*tokens, "--json", code=2))
        assert failure.get("ok") is False and failure.get("protocol_version") == 1, failure
        error = failure.get("error", {})
        assert error.get("code") == "E_USAGE" and isinstance(error.get("message"), str) and error["message"], failure
    no_side_effects()
    print(f"PASS {checks} offline help/schema/examples/guide checks; no daemon launch, socket or state creation")
