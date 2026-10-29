"""ElevenLabs Agents WebSocket transport. Credentials stay on the daemon.

The hosted agent must use PCM16 mono at 16 kHz in both directions. Its client
tools must match the local allowlist; use ``agent_config`` when provisioning it.
"""

from __future__ import annotations

import asyncio
import base64
import json
from collections.abc import AsyncIterator
from typing import Any
from urllib.parse import urlsplit

import httpx
import websockets

from .backend import (AudioOut, Event, Interrupted, ToolCalls, ToolResult, Transcript,
                      TranscriptCorrection, TurnComplete)
from .tools import Tool, ToolCall

API_URL = "https://api.elevenlabs.io/v1/convai"


def agent_config(instructions: str, tools: list[Tool], *, name: str = "agentring",
                 language: str = "es", voice: str | None = None, model: str | None = None) -> dict[str, Any]:
    """Configuration for a dedicated, authenticated agent (POST /agents/create).

    Creating/updating the hosted agent is an explicit setup step, never a side
    effect of starting a call. Re-export it after changing the local tools.
    """
    prompt: dict[str, Any] = {"prompt": instructions, "tools": [
        {"type": "client", "name": t.name, "description": t.description,
         "parameters": t.parameters, "expects_response": True, "response_timeout_secs": 120}
        for t in tools
    ]}
    if model:
        prompt["llm"] = model
    tts: dict[str, Any] = {"agent_output_audio_format": "pcm_16000"}
    if voice:
        tts["voice_id"] = voice
    return {
        "name": name,
        "conversation_config": {
            "agent": {"first_message": "", "language": language, "prompt": prompt},
            "asr": {"user_input_audio_format": "pcm_16000"}, "tts": tts,
            "conversation": {"max_duration_seconds": 600, "client_events": [
                "audio", "interruption", "user_transcript", "agent_response",
                "agent_response_correction", "client_tool_call",
            ]},
        },
        "platform_settings": {
            "auth": {"enable_auth": True},
            "overrides": {"conversation_config_override": {
                "agent": {"first_message": True, "prompt": {"prompt": True, "llm": True}},
                "tts": {"voice_id": True},
            }},
        },
    }


class ElevenLabs:
    input_rate = 16000
    output_rate = 16000
    max_session_s = 600

    def __init__(self, api_key: str, agent_id: str, *, voice: str | None = None,
                 model: str | None = None, api_url: str = API_URL):
        self.api_key, self.agent_id = api_key, agent_id
        self.voice, self.model, self.api_url = voice, model, api_url.rstrip("/")
        self._ws: Any = None
        self._tools: set[str] = set()
        self._last_interrupt_id = 0

    async def _send(self, message: dict[str, Any]) -> None:
        await self._ws.send(json.dumps(message))

    async def connect(self, instructions: str, tools: list[Tool]) -> None:
        self._tools = {t.name for t in tools}
        # Never put the API key in the WebSocket URL or in logs/exceptions.
        try:
            async with httpx.AsyncClient(timeout=20) as client:
                response = await client.get(f"{self.api_url}/conversation/get-signed-url",
                                            params={"agent_id": self.agent_id},
                                            headers={"xi-api-key": self.api_key})
                if response.status_code != 200:
                    raise RuntimeError(f"ElevenLabs authorization failed (HTTP {response.status_code})")
                url = response.json()["signed_url"]
            parsed = urlsplit(url)
            if self.api_url == API_URL and (parsed.scheme != "wss" or parsed.hostname != "api.elevenlabs.io"):
                raise RuntimeError("ElevenLabs returned an unexpected WebSocket address")
            self._ws = await websockets.connect(url, max_size=4 * 1024 * 1024, open_timeout=20)
            prompt: dict[str, Any] = {"prompt": instructions}
            if self.model:
                prompt["llm"] = self.model
            override: dict[str, Any] = {"agent": {"first_message": "", "prompt": prompt}}
            if self.voice:
                override["tts"] = {"voice_id": self.voice}
            await self._send({"type": "conversation_initiation_client_data",
                              "conversation_config_override": override})
            await asyncio.wait_for(self._metadata(), timeout=20)
        except BaseException as e:
            await self.close()
            if isinstance(e, (asyncio.CancelledError, RuntimeError)):
                raise
            raise RuntimeError("ElevenLabs connection failed; check the key, agent ID and override settings") from None

    async def _metadata(self) -> None:
        while True:
            message = json.loads(await self._ws.recv())
            if message.get("type") == "ping":
                await self._pong(message)
            elif message.get("type") == "conversation_initiation_metadata":
                meta = message["conversation_initiation_metadata_event"]
                if any(meta.get(k) != "pcm_16000" for k in
                       ("user_input_audio_format", "agent_output_audio_format")):
                    raise RuntimeError("ElevenLabs agent must use pcm_16000 for input and output; re-run setup")
                return
            else:
                raise RuntimeError("ElevenLabs setup failed before audio metadata; check the agent configuration")

    async def _pong(self, message: dict[str, Any]) -> None:
        await self._send({"type": "pong", "event_id": message["ping_event"]["event_id"]})

    async def send_audio(self, pcm: bytes) -> None:
        await self._send({"user_audio_chunk": base64.b64encode(pcm).decode()})

    async def send_text(self, text: str, *, respond: bool) -> None:
        await self._send({"type": "user_message" if respond else "contextual_update", "text": text})

    async def send_tool_results(self, results: list[ToolResult]) -> None:
        for r in results:
            await self._send({"type": "client_tool_result", "tool_call_id": r.call.id,
                              "result": r.output, "is_error": False})

    async def events(self) -> AsyncIterator[Event]:
        try:
            async for raw in self._ws:
                message = json.loads(raw)
                kind = message.get("type")
                if kind == "ping":
                    await self._pong(message)
                elif kind == "audio":
                    audio = message["audio_event"]
                    if int(audio["event_id"]) > self._last_interrupt_id:
                        yield AudioOut(base64.b64decode(audio["audio_base_64"], validate=True))
                elif kind == "interruption":
                    self._last_interrupt_id = int(message["interruption_event"]["event_id"])
                    yield Interrupted()
                elif kind in ("user_transcript", "agent_response"):
                    role, key, field = (("user", "user_transcription_event", "user_transcript")
                                        if kind == "user_transcript" else
                                        ("agent", "agent_response_event", "agent_response"))
                    text = message[key][field]
                    # These are complete snapshots, unlike Gemini's transcript deltas.
                    yield Transcript(role, text)
                    yield TurnComplete()
                elif kind == "agent_response_correction":
                    correction = message["agent_response_correction_event"]
                    yield TranscriptCorrection("agent", correction["original_agent_response"],
                                               correction["corrected_agent_response"])
                elif kind == "client_tool_call":
                    c = message["client_tool_call"]
                    if c["tool_name"] not in self._tools:
                        await self._send({"type": "client_tool_result", "tool_call_id": c["tool_call_id"],
                                          "result": "Tool is not enabled for this call", "is_error": True})
                        continue
                    yield ToolCalls([ToolCall(c["tool_call_id"], c["tool_name"], c.get("parameters") or {})])
                elif kind in ("error", "client_error"):
                    raise RuntimeError("ElevenLabs reported a conversation error")
        except websockets.exceptions.ConnectionClosedError as e:
            raise RuntimeError(f"ElevenLabs disconnected (code {e.rcvd.code if e.rcvd else 'unknown'})") from None

    async def close(self) -> None:
        if self._ws is not None:
            ws, self._ws = self._ws, None
            await ws.close()
