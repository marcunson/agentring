"""Direct speech must preserve OpenClaw's words, session and action ordering."""

import asyncio
import base64
import json

import httpx
import pytest
import websockets

pytest.importorskip("livekit")

from agentring.voice import AgentsConfig, CallInfo, CommandAgent, ElevenLabs, VoiceAgent
from agentring.voice.backend import AgentWaiting, AudioOut, Interrupted, Transcript
from agentring.voice.direct import OpenClawDirect
from agentring.voice.options import voice_options
from agentring.voice.quick import build_agent
from agentring.voice.session import CallSession


class Agent:
    def __init__(self):
        self.calls = []
        self.started = asyncio.Queue()
        self.replies = asyncio.Queue()

    async def ask(self, text, *, call_id=None):
        self.calls.append((text, call_id))
        self.started.put_nowait(len(self.calls))
        result = await self.replies.get()
        if isinstance(result, Exception):
            raise result
        return result


class Bytes(httpx.AsyncByteStream):
    async def __aiter__(self):
        # Deliberately split PCM16 samples across HTTP chunks.
        yield b"\x01"
        yield b"\x00\x02\x00"


def mock_tts(monkeypatch, *, status=200, stream=None):
    seen = []

    def handler(request):
        seen.append(request)
        return httpx.Response(status, stream=stream or Bytes())

    original = httpx.AsyncClient
    monkeypatch.setattr(httpx, "AsyncClient", lambda **kw: original(transport=httpx.MockTransport(handler), **kw))
    return seen


def ready():
    return json.dumps({"message_type": "session_started", "config": {
        "audio_format": "pcm_16000", "sample_rate": 16000}})


async def next_event(backend, cls):
    while True:
        event = await asyncio.wait_for(backend._events.get(), 3)
        if isinstance(event, Exception):
            raise event
        if isinstance(event, cls):
            return event


def test_transcript_goes_to_openclaw_and_exact_answer_to_tts(monkeypatch):
    requests = mock_tts(monkeypatch)
    received = asyncio.Queue()
    peers = asyncio.Queue()

    async def handler(ws):
        peers.put_nowait(ws)
        await ws.send(ready())
        async for raw in ws:
            received.put_nowait(json.loads(raw))

    async def run():
        async with websockets.serve(handler, "127.0.0.1", 0) as server:
            agent = Agent()
            backend = OpenClawDirect("private-key", "chosen-voice", agent,
                                     stt_url=f"ws://127.0.0.1:{server.sockets[0].getsockname()[1]}",
                                     tts_url="http://test/tts")
            try:
                await backend.connect("Be brief.", [])
                peer = await peers.get()
                assert peer.request.headers["xi-api-key"] == "private-key"
                assert "commit_strategy=vad" in peer.request.path
                await backend.send_audio(b"\x01\x00" * 1600)
                audio = await asyncio.wait_for(received.get(), 1)
                assert base64.b64decode(audio["audio_base_64"]) == b"\x01\x00" * 1600
                await backend.send_text("Caller joined", respond=False)
                await peer.send(json.dumps({"message_type": "committed_transcript", "text": "Comprueba la hora"}))
                assert await asyncio.wait_for(agent.started.get(), 2) == 1
                assert "Caller joined" in agent.calls[0][0] and "Be brief." in agent.calls[0][0]
                assert agent.calls[0][0].endswith("Comprueba la hora")
                assert (await next_event(backend, AgentWaiting)).active
                answer = "Son las doce. Esto es exactamente lo que respondió OpenClaw."
                agent.replies.put_nowait(answer)
                assert not (await next_event(backend, AgentWaiting)).active
                transcript = await next_event(backend, Transcript)
                assert transcript.role == "agent" and transcript.text == answer
                assert (await next_event(backend, AudioOut)).pcm == b"\x01\x00\x02\x00"
                # A second turn shares only this call's session, without re-sending history.
                await peer.send(json.dumps({"message_type": "committed_transcript", "text": "¿Y mañana?"}))
                await asyncio.wait_for(agent.started.get(), 2)
                assert agent.calls[1] == ("¿Y mañana?", agent.calls[0][1])
                assert backend.call_id != OpenClawDirect("x", "y", agent).call_id
            finally:
                await backend.close()

    asyncio.run(run())
    assert len(requests) == 1
    assert json.loads(requests[0].content)["text"].endswith("respondió OpenClaw.")
    assert requests[0].url.path == "/tts/chosen-voice/stream"
    assert requests[0].url.params["output_format"] == "pcm_16000"
    assert "private-key" not in str(requests[0].url)


def test_interruption_waits_for_running_action_and_never_replays_it(monkeypatch):
    requests = mock_tts(monkeypatch)
    peers = asyncio.Queue()

    async def handler(ws):
        peers.put_nowait(ws)
        await ws.send(ready())
        await ws.wait_closed()

    async def run():
        async with websockets.serve(handler, "127.0.0.1", 0) as server:
            agent = Agent()
            backend = OpenClawDirect("key", "voice", agent,
                                     stt_url=f"ws://127.0.0.1:{server.sockets[0].getsockname()[1]}")
            try:
                await backend.connect("brief", [])
                peer = await peers.get()
                await peer.send(json.dumps({"message_type": "committed_transcript", "text": "Primera acción"}))
                await asyncio.wait_for(agent.started.get(), 2)
                # Drain until the first job starts, then interrupt while it still works.
                await next_event(backend, AgentWaiting)
                await peer.send(json.dumps({"message_type": "partial_transcript", "text": "Segunda"}))
                assert isinstance(await next_event(backend, Interrupted), Interrupted)
                await peer.send(json.dumps({"message_type": "committed_transcript", "text": "Segunda acción"}))
                await next_event(backend, Transcript)
                assert len(agent.calls) == 1
                agent.replies.put_nowait("First result, superseded by the next utterance")
                assert await asyncio.wait_for(agent.started.get(), 2) == 2
                assert len(requests) == 0  # do not speak the stale response over the new request
                agent.replies.put_nowait("Respuesta a la segunda")
                await next_event(backend, AudioOut)
                assert [t for t, _ in agent.calls][1:] == ["Segunda acción"]
                assert len(requests) == 1
            finally:
                await backend.close()

    asyncio.run(run())


def test_user_can_interrupt_tts_without_closing_the_call(monkeypatch):
    class Slow(Bytes):
        async def __aiter__(self):
            yield b"\x01\x00" * 1600
            await asyncio.Event().wait()

    requests = mock_tts(monkeypatch, stream=Slow())
    peers = asyncio.Queue()

    async def handler(ws):
        peers.put_nowait(ws)
        await ws.send(ready())
        await ws.wait_closed()

    async def run():
        async with websockets.serve(handler, "127.0.0.1", 0) as server:
            agent = Agent()
            backend = OpenClawDirect("key", "voice", agent,
                                     stt_url=f"ws://127.0.0.1:{server.sockets[0].getsockname()[1]}")
            try:
                await backend.connect("brief", [])
                peer = await peers.get()
                await backend.send_text("Greet the caller", respond=True)
                await agent.started.get()
                agent.replies.put_nowait("Hola")
                await next_event(backend, AudioOut)
                await peer.send(json.dumps({"message_type": "partial_transcript", "text": "Espera"}))
                await next_event(backend, Interrupted)
                await peer.send(json.dumps({"message_type": "committed_transcript", "text": "Espera un momento"}))
                assert await asyncio.wait_for(agent.started.get(), 2) == 2
                assert not backend._closed and len(requests) == 1
            finally:
                await backend.close()
                assert all(t.done() for t in backend._tasks)

    asyncio.run(run())


def test_failed_action_is_reported_once_without_retry(monkeypatch):
    requests = mock_tts(monkeypatch)

    async def handler(ws):
        await ws.send(ready())
        await ws.wait_closed()

    async def run():
        async with websockets.serve(handler, "127.0.0.1", 0) as server:
            agent = Agent()
            backend = OpenClawDirect("key", "voice", agent,
                                     stt_url=f"ws://127.0.0.1:{server.sockets[0].getsockname()[1]}")
            try:
                await backend.connect("brief", [])
                await backend.send_text("Greet", respond=True)
                await agent.started.get()
                agent.replies.put_nowait(RuntimeError("private detail"))
                assert (await next_event(backend, AgentWaiting)).active
                assert not (await next_event(backend, AgentWaiting)).active
                await next_event(backend, AudioOut)
                assert len(agent.calls) == 1
            finally:
                await backend.close()

    asyncio.run(run())
    text = json.loads(requests[0].content)["text"]
    assert "no ha podido" in text and "private detail" not in text


def test_stt_setup_error_is_redacted_and_closed():
    async def handler(ws):
        await ws.send(json.dumps({"message_type": "auth_error", "error": "private-key"}))
        await ws.wait_closed()

    async def run():
        async with websockets.serve(handler, "127.0.0.1", 0) as server:
            backend = OpenClawDirect("private-key", "voice", Agent(),
                                     stt_url=f"ws://127.0.0.1:{server.sockets[0].getsockname()[1]}")
            with pytest.raises(RuntimeError, match="permissions") as caught:
                await backend.connect("brief", [])
            assert "private-key" not in str(caught.value)
            assert backend._ws is None and not backend._tasks

    asyncio.run(run())


def test_direct_provider_is_additional_and_requires_explicit_voice_and_agent(agentring_home, monkeypatch):
    monkeypatch.setenv("AGENTRING_VOICE_PROVIDER", "elevenlabs")
    monkeypatch.setenv("ELEVENLABS_API_KEY", "key")
    monkeypatch.setenv("ELEVENLABS_AGENT_ID", "existing-agent")
    monkeypatch.setenv("ELEVENLABS_VOICE_ID", "direct-voice")
    assert voice_options()["agent_id"] == "existing-agent"
    options = voice_options("openclaw-elevenlabs")
    assert "agent_id" not in options and options["voice_id"] == "direct-voice"
    cfg = AgentsConfig([CommandAgent("openclaw", "brain", ["echo"])])

    async def run():
        built = await build_agent(**options, agents=cfg)
        assert isinstance(built.agent.backend(), OpenClawDirect)
        assert not built.agent.tools and not built.agent.end_call_tool and built.consultations is None
        await built.aclose()
        previous = await build_agent(**voice_options(), agents=cfg)
        assert isinstance(previous.agent.backend(), ElevenLabs)
        assert [t.name for t in previous.agent.tools] == ["consult_agent"]
        await previous.aclose()
        with pytest.raises(ValueError, match="command agent"):
            await build_agent(**options)
        with pytest.raises(ValueError, match="ELEVENLABS_VOICE_ID"):
            await build_agent("key", provider="openclaw-elevenlabs", agents=cfg)
        with pytest.raises(ValueError, match="OpenClaw's model"):
            await build_agent(**options, agents=cfg, model="unwanted-model")
        with pytest.raises(ValueError, match="OpenClaw's own tools"):
            await build_agent(**options, agents=cfg, mcp=["http://test"])

    asyncio.run(run())


def test_wait_events_use_existing_hold_music_and_clear_on_completion():
    class Backend:
        input_rate = output_rate = 16000
        max_session_s = None

        async def close(self):
            pass

    async def run():
        s = CallSession(VoiceAgent(Backend, "brief"), CallInfo("direct"))
        try:
            s.handle_event(AgentWaiting(True))
            assert len(s._hold_tokens) == 1
            s.handle_event(AgentWaiting(True))
            assert len(s._hold_tokens) == 1
            s.handle_event(AgentWaiting(False))
            assert not s._hold_tokens
            s.finish("hung_up")
            s.handle_event(AgentWaiting(True))
            assert not s._hold_tokens
        finally:
            await s.stop(end_call=False)
            await s.source.aclose()

    asyncio.run(run())
