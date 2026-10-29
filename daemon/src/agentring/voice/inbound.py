"""Answering calls the user makes to the agent (M4, "Call agent" in the app)."""

from __future__ import annotations

import logging
import time
from collections.abc import Awaitable, Callable
from typing import Any

from ..relay_client import RelayError

log = logging.getLogger("agentring.voice")

VOICE_PROVIDERS = {"elevenlabs": "elevenlabs", "openclaw_direct": "openclaw-elevenlabs"}


class InboundVoiceModes:
    """Choose an explicitly requested mode without changing the daemon default.

    Alternatives are built once, on demand. Missing/unknown modes fail instead
    of falling back to a different conversational agent.
    """

    def __init__(self, default: Any, provider: str, build: Callable[[str], Awaitable[Any]]):
        self._built = {"default": default}
        self._built.update({mode: default for mode, p in VOICE_PROVIDERS.items() if p == provider})
        self._build = build

    async def for_event(self, event: dict[str, Any]) -> Any:
        mode = event.get("voice_mode", "default")
        if not isinstance(mode, str) or mode not in {"default", *VOICE_PROVIDERS}:
            raise ValueError("Unsupported call voice mode")
        if mode not in self._built:
            self._built[mode] = await self._build(VOICE_PROVIDERS[mode])
        return self._built[mode].agent

    async def aclose(self) -> None:
        for built in {id(b): b for b in self._built.values()}.values():
            await built.aclose()


def is_incoming_call(event: dict[str, Any], now: float | None = None) -> bool:
    """A `call.invite` from a phone to the agent that still rings (replayed old invites don't count)."""
    if event.get("type") != "call.invite" or event.get("direction") != "user_to_agent":
        return False
    return (event.get("expires_at") or 0) / 1000 > (time.time() if now is None else now)


def accept_incoming(client: Any, event: dict[str, Any]) -> tuple[Any, dict[str, Any]] | None:
    """Accepts an incoming call. Returns what VoiceAgent.run needs, or None if it isn't
    one (or someone else took it first). `client` is a RelayClient."""
    from .session import CallInfo

    if not is_incoming_call(event):
        return None
    try:
        res = client.accept_call(event["call_id"])
    except RelayError as e:
        log.warning("could not accept call %s: %s", event["call_id"], e)
        return None
    call = res.get("call") or {}
    return CallInfo(event["call_id"], event.get("reason") or call.get("reason") or "", "user_to_agent"), res["join"]
