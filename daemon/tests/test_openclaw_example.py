"""Protect the example's process boundary and per-call conversation routing."""

import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

BRIDGE = Path(__file__).resolve().parents[2] / "examples/openclaw/ask.py"


def fake_cli(tmp_path, body):
    executable = tmp_path / "openclaw"
    executable.write_text(f"#!{sys.executable}\n" + body)
    executable.chmod(0o700)
    return executable


def test_openclaw_bridge_preserves_tasks_and_session(tmp_path):
    record = tmp_path / "record.json"
    executable = fake_cli(tmp_path, '''import json,os,sys,stat
from pathlib import Path
args=sys.argv[1:]
prompt=Path(args[args.index('--message-file')+1])
Path(os.environ['BRIDGE_RECORD']).write_text(json.dumps({'args':args,'task':prompt.read_text(),
    'mode':stat.S_IMODE(prompt.stat().st_mode),'path':str(prompt)}))
print(json.dumps({'status':'ok','result':{'payloads':[{'text':'Respuesta de OpenClaw'},{'text':'Segunda frase'}],
                                      'meta':{'private':'must not be spoken'}}}))
''')
    env = {**os.environ, "AGENTRING_OPENCLAW_BIN": str(executable), "AGENTRING_OPENCLAW_AGENT": "main",
           "AGENTRING_CALL_ID": "call_example", "BRIDGE_RECORD": str(record)}
    task = 'Primera línea\n$(touch /tmp/never-run-this) "acentos: áéí"'
    result = subprocess.run([sys.executable, str(BRIDGE)], input=task, env=env,
                            text=True, capture_output=True, check=True)
    assert result.stdout == "Respuesta de OpenClaw\nSegunda frase\n"
    data = json.loads(record.read_text())
    assert data["task"] == task and data["mode"] == 0o600
    assert not Path(data["path"]).exists()
    assert "--deliver" not in data["args"] and task not in data["args"]
    assert data["args"][data["args"].index("--session-key") + 1] == "agent:main:agentring-call_example"


@pytest.mark.parametrize("call_id", ["call_delegated", "direct-call_example", None])
def test_voice_model_and_thinking_are_scoped_to_call_requests(tmp_path, call_id):
    record = tmp_path / "record.json"
    executable = fake_cli(tmp_path, '''import json,os,sys
from pathlib import Path
Path(os.environ['BRIDGE_RECORD']).write_text(json.dumps(sys.argv[1:]))
print(json.dumps({'status':'ok','result':{'payloads':[{'text':'Fast reply'}]}}))
''')
    env = {**os.environ, "AGENTRING_OPENCLAW_BIN": str(executable), "BRIDGE_RECORD": str(record),
           "AGENTRING_OPENCLAW_VOICE_MODEL": "openai/gpt-5.6-luna", "AGENTRING_OPENCLAW_VOICE_THINKING": "low"}
    env.pop("AGENTRING_CALL_ID", None)
    if call_id:
        env["AGENTRING_CALL_ID"] = call_id
    result = subprocess.run([sys.executable, str(BRIDGE)], input="Test task", env=env,
                            text=True, capture_output=True, check=True)
    args = json.loads(record.read_text())
    assert result.stdout == "Fast reply\n"
    assert "--deliver" not in args and "--channel" not in args
    assert "models" not in args and "set" not in args  # no configuration-writing command
    if call_id:
        assert args[args.index("--model") + 1] == "openai/gpt-5.6-luna"
        assert args[args.index("--thinking") + 1] == "low"
        assert args[args.index("--session-key") + 1].endswith("agentring-" + call_id)
    else:
        assert "--model" not in args and "--thinking" not in args


@pytest.mark.parametrize("overrides", [
    {"AGENTRING_OPENCLAW_VOICE_MODEL": "--deliver"},
    {"AGENTRING_OPENCLAW_VOICE_MODEL": "model\n--deliver"},
    {"AGENTRING_OPENCLAW_VOICE_THINKING": "instant"},
])
def test_invalid_voice_settings_fail_before_executing_openclaw(tmp_path, overrides):
    executable = fake_cli(tmp_path, "raise AssertionError('CLI must not run')\n")
    result = subprocess.run([sys.executable, str(BRIDGE)], input="test",
                            env={**os.environ, "AGENTRING_CALL_ID": "call_test",
                                 "AGENTRING_OPENCLAW_BIN": str(executable), **overrides},
                            text=True, capture_output=True)
    assert result.returncode != 0 and not result.stdout
    assert "AGENTRING_OPENCLAW_VOICE_" in result.stderr
    assert "CLI must not run" not in result.stderr


@pytest.mark.parametrize("body", [
    "import sys\nprint('private diagnostic',file=sys.stderr)\nsys.exit(1)\n",
    "print('not JSON')\n",
    "print('{\"status\":\"in_flight\"}')\n",
    "print('{\"status\":\"ok\",\"result\":{\"payloads\":[]}}')\n",
])
def test_openclaw_bridge_reports_failure_without_leaking_diagnostics(tmp_path, body):
    executable = fake_cli(tmp_path, body)
    result = subprocess.run([sys.executable, str(BRIDGE)], input="test",
                            env={**os.environ, "AGENTRING_OPENCLAW_BIN": str(executable)},
                            text=True, capture_output=True)
    assert result.returncode != 0 and not result.stdout
    assert "private diagnostic" not in result.stderr
