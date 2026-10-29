#!/usr/bin/env python3
"""Command-agent bridge: task on stdin, only OpenClaw's reply on stdout."""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import uuid


def voice_overrides(call_id: str | None) -> list[str]:
    """Per-run settings only for phone calls, never global or Telegram defaults."""
    if not call_id:
        return []
    model = os.environ.get("AGENTRING_OPENCLAW_VOICE_MODEL", "").strip()
    thinking = os.environ.get("AGENTRING_OPENCLAW_VOICE_THINKING", "").strip().lower()
    if model and (model.startswith("-") or len(model) > 256 or any(c.isspace() or ord(c) < 32 for c in model)):
        raise SystemExit("AGENTRING_OPENCLAW_VOICE_MODEL must be a single model id or alias.")
    if thinking and thinking not in {"off", "minimal", "low", "medium", "high", "xhigh", "adaptive", "max", "ultra"}:
        raise SystemExit("AGENTRING_OPENCLAW_VOICE_THINKING is not a supported thinking level.")
    return (["--model", model] if model else []) + (["--thinking", thinking] if thinking else [])


def main() -> None:
    executable = os.environ.get("AGENTRING_OPENCLAW_BIN") or shutil.which("openclaw")
    if not executable:
        raise SystemExit("OpenClaw is not on PATH; set AGENTRING_OPENCLAW_BIN to its absolute path.")
    task = sys.stdin.read()
    if not task.strip():
        raise SystemExit("The task on stdin is empty.")
    agent = os.environ.get("AGENTRING_OPENCLAW_AGENT", "main")
    call = os.environ.get("AGENTRING_CALL_ID")
    overrides = voice_overrides(call)
    session = f"agent:{agent}:agentring-{call or uuid.uuid4()}"
    try:
        # Older OpenClaw versions accept a path but not '-' for stdin. Keep task
        # text out of process arguments with a private, automatically removed file.
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", suffix="-agentring.txt") as prompt:
            prompt.write(task)
            prompt.flush()
            result = subprocess.run(
                [executable, "agent", "--agent", agent, "--session-key", session,
                 "--message-file", prompt.name, "--timeout", "90", "--json", *overrides],
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
