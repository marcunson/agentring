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
