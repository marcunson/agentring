#!/usr/bin/env python3
"""Command-agent bridge: task on stdin, only OpenClaw's reply on stdout."""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import uuid


def main() -> None:
    executable = os.environ.get("AGENTRING_OPENCLAW_BIN") or shutil.which("openclaw")
    if not executable:
        raise SystemExit("OpenClaw is not on PATH; set AGENTRING_OPENCLAW_BIN to its absolute path.")
    task = sys.stdin.read()
    if not task.strip():
        raise SystemExit("The task on stdin is empty.")
    agent = os.environ.get("AGENTRING_OPENCLAW_AGENT", "main")
    call = os.environ.get("AGENTRING_CALL_ID") or str(uuid.uuid4())
    session = f"agent:{agent}:agentring-{call}"
    try:
        # Older OpenClaw versions accept a path but not '-' for stdin. Keep task
        # text out of process arguments with a private, automatically removed file.
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", suffix="-agentring.txt") as prompt:
            prompt.write(task)
            prompt.flush()
            result = subprocess.run(
                [executable, "agent", "--agent", agent, "--session-key", session,
                 "--message-file", prompt.name, "--timeout", "90", "--json"],
                text=True, encoding="utf-8", capture_output=True, timeout=120,
            )
    except subprocess.TimeoutExpired:
        raise SystemExit("OpenClaw transport timed out; check its session before retrying.") from None
    if result.returncode:
        raise SystemExit(f"OpenClaw request failed (exit {result.returncode}); check the local gateway logs.")
    try:
        envelope = json.loads(result.stdout)
    except ValueError:
        raise SystemExit("OpenClaw returned invalid JSON; check its CLI version.") from None
    if envelope.get("ok") is False or envelope.get("status") not in (None, "ok", "completed"):
        raise SystemExit("OpenClaw did not complete the request; check its session before retrying.")
    body = envelope.get("result", envelope)
    text = "\n".join(p["text"] for p in body.get("payloads", []) if p.get("text"))
    if not text.strip():
        raise SystemExit("OpenClaw completed without a text reply.")
    print(text.strip())


if __name__ == "__main__":
    main()
