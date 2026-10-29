"""Exercise the HTTP/WS boundary without a paid account or a phone."""

import asyncio
import base64
import json

import httpx
import pytest
import websockets
from typer.testing import CliRunner

pytest.importorskip("livekit")

from agentring.cli import app
from agentring.config import write_settings
from agentring.voice import CallInfo, ElevenLabs, Tool, VoiceAgent
from agentring.voice.backend import (AudioOut, Interrupted, ToolCalls, ToolResult, Transcript,
                                     TranscriptCorrection, TurnComplete)
from agentring.voice.elevenlabs import agent_config
from agentring.voice.options import voice_options
from agentring.voice.quick import build_agent
from agentring.voice.session import CallSession


def signed_url(monkeypatch, url, *, status=200):
    seen = []

    def handler(request):
        seen.append(request)
        return httpx.Response(status, json={"signed_url": url})

    original = httpx.AsyncClient
    monkeypatch.setattr(httpx, "AsyncClient", lambda **kw: original(transport=httpx.MockTransport(handler), **kw))
    return seen


def test_elevenlabs_wire_protocol(monkeypatch):
    seen = []
    pcm = b"\x01\x00" * 320

    async def handler(ws):
        seen.append(json.loads(await ws.recv()))
        await ws.send(json.dumps({"type": "ping", "ping_event": {"event_id": 1}}))
        seen.append(json.loads(await ws.recv()))
        await ws.send(json.dumps({"type": "conversation_initiation_metadata", "conversation_initiation_metadata_event": {
            "user_input_audio_format": "pcm_16000", "agent_output_audio_format": "pcm_16000"}}))
        for _ in range(3):
            seen.append(json.loads(await ws.recv()))
        for message in [
            {"type": "user_transcript", "user_transcription_event": {"user_transcript": "Hola"}},
            {"type": "agent_response", "agent_response_event": {"agent_response": "Hola Marc, ¿qué tal?"}},
            {"type": "audio", "audio_event": {"audio_base_64": base64.b64encode(pcm).decode(), "event_id": 2}},
            {"type": "interruption", "interruption_event": {"event_id": 3}},
            # A late chunk from the interrupted response must never be played.
            {"type": "audio", "audio_event": {"audio_base_64": base64.b64encode(pcm).decode(), "event_id": 2}},
            {"type": "agent_response_correction", "agent_response_correction_event": {
                "original_agent_response": "Hola Marc, ¿qué tal?", "corrected_agent_response": "Hola Marc"}},
            {"type": "ping", "ping_event": {"event_id": 4}},
            {"type": "client_tool_call", "client_tool_call": {
                "tool_call_id": "denied", "tool_name": "not_allowed", "parameters": {}}},
            {"type": "client_tool_call", "client_tool_call": {
                "tool_call_id": "c1", "tool_name": "consult_agent", "parameters": {"task": "check"}}},
        ]:
            await ws.send(json.dumps(message))
        for _ in range(3):
            seen.append(json.loads(await ws.recv()))
        await ws.close()

    async def run():
        server = await websockets.serve(handler, "127.0.0.1", 0)
        url = f"ws://127.0.0.1:{server.sockets[0].getsockname()[1]}"
        requests = signed_url(monkeypatch, url)
        backend = ElevenLabs("private-key", "agent_test", voice="voice_test", model="test-llm", api_url="http://test")
        try:
            await backend.connect("Be brief.", [Tool("consult_agent", "Ask an agent", lambda: None)])
            await backend.send_audio(pcm)
            await backend.send_text("Answered", respond=True)
            await backend.send_text("Some context", respond=False)
            events = []
            async for event in backend.events():
                events.append(event)
                if isinstance(event, ToolCalls):
                    await backend.send_tool_results([ToolResult(event.calls[0], "Done")])
            call = CallSession(VoiceAgent(lambda: ElevenLabs("unused", "unused"), "brief"), CallInfo("test"))
            try:
                for event in events:
                    if not isinstance(event, ToolCalls):
                        call.handle_event(event)
                assert call.transcript == [("user", "Hola"), ("agent", "Hola Marc")]
            finally:
                await call.stop(end_call=False)
            return requests, events
        finally:
            await backend.close()
            server.close()
            await server.wait_closed()

    requests, events = asyncio.run(run())
    assert requests[0].headers["xi-api-key"] == "private-key"
    assert requests[0].url.params["agent_id"] == "agent_test"
    assert "private-key" not in str(requests[0].url)
    override = seen[0]["conversation_config_override"]
    assert override == {"agent": {"first_message": "", "prompt": {"prompt": "Be brief.", "llm": "test-llm"}},
                        "tts": {"voice_id": "voice_test"}}
    assert seen[1] == {"type": "pong", "event_id": 1}
    assert seen[2] == {"user_audio_chunk": base64.b64encode(pcm).decode()}
    assert seen[3] == {"type": "user_message", "text": "Answered"}
    assert seen[4] == {"type": "contextual_update", "text": "Some context"}
    assert seen[5] == {"type": "pong", "event_id": 4}
    assert seen[6]["tool_call_id"] == "denied" and seen[6]["is_error"] is True
    assert seen[7] == {"type": "client_tool_result", "tool_call_id": "c1", "result": "Done", "is_error": False}
    assert [type(e) for e in events] == [Transcript, TurnComplete, Transcript, TurnComplete,
                                        AudioOut, Interrupted, TranscriptCorrection, ToolCalls]
    assert next(e for e in events if isinstance(e, AudioOut)).pcm == pcm


@pytest.mark.parametrize("audio_format", ["pcm_24000", "ulaw_8000"])
def test_rejects_incompatible_audio_and_closes(monkeypatch, audio_format):
    async def handler(ws):
        await ws.recv()
        await ws.send(json.dumps({"type": "conversation_initiation_metadata", "conversation_initiation_metadata_event": {
            "user_input_audio_format": "pcm_16000", "agent_output_audio_format": audio_format}}))
        await ws.wait_closed()

    async def run():
        async with websockets.serve(handler, "127.0.0.1", 0) as server:
            signed_url(monkeypatch, f"ws://127.0.0.1:{server.sockets[0].getsockname()[1]}")
            backend = ElevenLabs("private-key", "agent_test", api_url="http://test")
            with pytest.raises(RuntimeError, match="pcm_16000"):
                await backend.connect("brief", [])
            assert backend._ws is None

    asyncio.run(run())


def test_auth_failure_is_redacted(monkeypatch):
    signed_url(monkeypatch, "wss://bad.example/?secret=private-key", status=401)
    with pytest.raises(RuntimeError, match="HTTP 401") as caught:
        asyncio.run(ElevenLabs("private-key", "agent_test").connect("brief", []))
    assert "private-key" not in str(caught.value)


def test_unexpected_signed_url_is_rejected(monkeypatch):
    signed_url(monkeypatch, "wss://bad.example/?secret=private-key")
    with pytest.raises(RuntimeError, match="unexpected WebSocket"):
        asyncio.run(ElevenLabs("private-key", "agent_test").connect("brief", []))


def test_provider_selection_and_local_dotenv(agentring_home, monkeypatch):
    for name in ("AGENTRING_VOICE_PROVIDER", "ELEVENLABS_API_KEY", "ELEVENLABS_AGENT_ID", "GEMINI_API_KEY"):
        monkeypatch.delenv(name, raising=False)
    with pytest.raises(ValueError, match="GEMINI_API_KEY"):
        voice_options()
    agentring_home.mkdir()
    (agentring_home / ".env").write_text("AGENTRING_VOICE_PROVIDER=elevenlabs\nELEVENLABS_API_KEY=private\n"
                                         "ELEVENLABS_AGENT_ID=agent_test\n")
    assert voice_options() == {"provider": "elevenlabs", "api_key": "private", "agent_id": "agent_test"}
    monkeypatch.setenv("GEMINI_API_KEY", "gemini-key")
    assert voice_options("gemini") == {"provider": "gemini", "api_key": "gemini-key"}
    monkeypatch.setenv("AGENTRING_VOICE_PROVIDER", "unknown")
    with pytest.raises(ValueError, match="provider"):
        voice_options()
    monkeypatch.setenv("ELEVENLABS_API_KEY", "key")
    (agentring_home / ".env").unlink()
    with pytest.raises(ValueError, match="ELEVENLABS_AGENT_ID"):
        voice_options("elevenlabs")


@pytest.mark.parametrize("arguments", [["serve", "--ai"], ["call", "test", "--ai"]])
def test_cli_provider_overrides_default(arguments, agentring_home, monkeypatch):
    write_settings("http://127.0.0.1:1", "ak_unused")
    monkeypatch.setenv("AGENTRING_VOICE_PROVIDER", "gemini")
    monkeypatch.setenv("ELEVENLABS_API_KEY", "test-key")
    monkeypatch.delenv("ELEVENLABS_AGENT_ID", raising=False)
    result = CliRunner().invoke(app, [*arguments, "--provider", "elevenlabs"])
    assert result.exit_code == 1
    assert "ELEVENLABS_AGENT_ID" in result.output


def test_build_and_export_with_consultations(agentring_home):
    agentring_home.mkdir()
    (agentring_home / "agents.yaml").write_text('agents:\n  openclaw:\n    description: Ask OpenClaw\n'
                                              '    command: [echo, "{task}"]\n')
    result = CliRunner().invoke(app, ["elevenlabs-config"])
    assert result.exit_code == 0, result.output
    cfg = json.loads(result.output)
    tools = cfg["conversation_config"]["agent"]["prompt"]["tools"]
    assert {t["name"] for t in tools} == {"consult_agent", "end_call"}
    assert next(t for t in tools if t["name"] == "consult_agent")["pre_tool_speech"] == "force"
    assert all(t["type"] == "client" and t["expects_response"] for t in tools)
    assert cfg["platform_settings"]["auth"]["enable_auth"] is True
    assert cfg["conversation_config"]["tts"]["agent_output_audio_format"] == "pcm_16000"

    async def run():
        built = await build_agent("key", provider="elevenlabs", agent_id="agent_test")
        assert isinstance(built.agent.backend(), ElevenLabs)
        await built.aclose()
        with pytest.raises(ValueError, match="agent_id"):
            await build_agent("key", provider="elevenlabs")

    asyncio.run(run())


def test_config_leaves_provider_voice_and_model_defaults():
    config = agent_config("brief", [])
    assert "voice_id" not in config["conversation_config"]["tts"]
    assert "llm" not in config["conversation_config"]["agent"]["prompt"]


def test_provider_error_ends_the_call():
    class Broken(ElevenLabs):
        async def events(self):
            raise RuntimeError("provider unavailable")
            yield  # makes this an async generator

    async def run():
        session = CallSession(VoiceAgent(lambda: Broken("unused", "unused"), "brief"), CallInfo("test"))
        try:
            await session._model_loop()
            assert session.done.is_set() and session.end_reason == "error"
            assert "provider unavailable" in session.error
        finally:
            await session.stop(end_call=False)

    asyncio.run(run())
