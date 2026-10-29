"""OpenClaw is the conversational agent; ElevenLabs only transcribes and speaks.

No hosted ElevenLabs Agent or public gateway endpoint is needed. Each backend
has its own OpenClaw session, and turns run serially so actions are never replayed
or overlapped by an interruption. Interrupting cancels speech, not agent work.
"""

from __future__ import annotations

import asyncio
import base64
import json
import logging
import uuid
from collections.abc import AsyncIterator
from typing import Any
from urllib.parse import urlencode, quote

import httpx
import websockets

from .agents import CommandAgent
from .backend import AgentWaiting, AudioOut, Event, Interrupted, ToolResult, Transcript, TurnComplete
from .tools import Tool

log = logging.getLogger("agentring.voice.direct")
STT_URL = "wss://api.elevenlabs.io/v1/speech-to-text/realtime"
TTS_URL = "https://api.elevenlabs.io/v1/text-to-speech"
PHONE_CONTEXT = (
    "This is a live voice call. You are speaking directly to the caller; there is no other conversational AI. "
    "Answer in Spanish unless the caller uses another language. Be brief and natural, without Markdown, "
    "code blocks, raw URLs or paths. Use your own tools when needed and report their actual results. "
    "Local hold music plays while you work. Do not claim the call has ended; the caller hangs up in the app."
)


class OpenClawDirect:
    input_rate = output_rate = 16000
    max_session_s = 600

    def __init__(self, api_key: str, voice_id: str, agent: CommandAgent, *,
                 tts_model: str = "eleven_flash_v2_5", language: str = "es",
                 stt_url: str = STT_URL, tts_url: str = TTS_URL):
        self.api_key, self.voice_id, self.agent = api_key, voice_id, agent
        self.tts_model, self.language = tts_model, language
        self.stt_url, self.tts_url = stt_url, tts_url.rstrip("/")
        self.call_id = f"direct-{uuid.uuid4()}"
        self._ws: Any = None
        self._http: httpx.AsyncClient | None = None
        self._tasks: list[asyncio.Task] = []
        self._speech: asyncio.Task | None = None
        self._events: asyncio.Queue[Event | Exception] = asyncio.Queue()
        self._turns: asyncio.Queue[tuple[int, str]] = asyncio.Queue()
        self._input = bytearray()
        self._context: list[str] = []
        self._instructions = ""
        self._first = True
        self._closed = False
        self._generation = 0
        self._utterance_started = False
        self._last_partial = ""
        self._last_input_at = 0.0

    async def connect(self, instructions: str, tools: list[Tool]) -> None:
        if any(t.name != "end_call" for t in tools):
            raise ValueError("Direct mode uses OpenClaw's own tools; configure them in OpenClaw")
        self._instructions = instructions
        query = urlencode({"model_id": "scribe_v2_realtime", "audio_format": "pcm_16000",
                           "language_code": self.language, "commit_strategy": "vad",
                           "vad_silence_threshold_secs": "1.0"})
        try:
            self._ws = await websockets.connect(f"{self.stt_url}?{query}",
                                               additional_headers={"xi-api-key": self.api_key},
                                               open_timeout=20, max_size=1024 * 1024)
            message = json.loads(await asyncio.wait_for(self._ws.recv(), 20))
            if message.get("message_type") != "session_started":
                raise RuntimeError("ElevenLabs transcription setup failed; check Speech to Text permissions")
            config = message.get("config", {})
            if config.get("sample_rate") != self.input_rate or config.get("audio_format") != "pcm_16000":
                raise RuntimeError("ElevenLabs transcription must use pcm_16000")
            self._http = httpx.AsyncClient(timeout=httpx.Timeout(60, connect=20))
            self._last_input_at = asyncio.get_running_loop().time()
            self._tasks = [asyncio.create_task(self._listen()), asyncio.create_task(self._work()),
                           asyncio.create_task(self._silence())]
        except BaseException as e:
            await self.close()
            if isinstance(e, (asyncio.CancelledError, RuntimeError)):
                raise
            raise RuntimeError("ElevenLabs transcription connection failed; check the API key and permissions") from None

    async def send_audio(self, pcm: bytes) -> None:
        self._last_input_at = asyncio.get_running_loop().time()
        self._input += pcm
        chunk = self.input_rate // 10 * 2  # 100 ms PCM16, including silence while the caller listens
        while len(self._input) >= chunk:
            audio = bytes(self._input[:chunk])
            del self._input[:chunk]
            await self._ws.send(json.dumps({"message_type": "input_audio_chunk",
                                           "audio_base_64": base64.b64encode(audio).decode(),
                                           "sample_rate": self.input_rate}))

    async def _silence(self) -> None:
        """Keep STT alive when a muted/disconnected microphone sends no frames."""
        try:
            while True:
                await asyncio.sleep(0.1)
                if asyncio.get_running_loop().time() - self._last_input_at >= 0.3:
                    await self._ws.send(json.dumps({"message_type": "input_audio_chunk",
                                                   "audio_base_64": base64.b64encode(b"\0" * 3200).decode(),
                                                   "sample_rate": self.input_rate}))
        except asyncio.CancelledError:
            raise
        except Exception:
            self._events.put_nowait(RuntimeError("ElevenLabs transcription connection stopped"))

    async def send_text(self, text: str, *, respond: bool) -> None:
        if respond:
            self._turns.put_nowait((self._generation, f"Call event (not a user utterance): {text}"))
        else:
            self._context.append(text)

    async def send_tool_results(self, results: list[ToolResult]) -> None:
        raise RuntimeError("Direct mode does not delegate tools through ElevenLabs")

    def _interrupt(self) -> None:
        if not self._utterance_started:
            self._generation += 1
            self._utterance_started = True
        if self._speech is not None:
            self._speech.cancel()
        self._events.put_nowait(Interrupted())

    async def _listen(self) -> None:
        try:
            async for raw in self._ws:
                message = json.loads(raw)
                kind, text = message.get("message_type", ""), message.get("text", "").strip()
                if kind == "partial_transcript" and text and text != self._last_partial:
                    self._last_partial = text
                    self._interrupt()
                elif kind == "committed_transcript":
                    if text:
                        self._interrupt()
                        self._events.put_nowait(Transcript("user", text))
                        self._events.put_nowait(TurnComplete())
                        self._turns.put_nowait((self._generation, text))
                    self._utterance_started, self._last_partial = False, ""
                elif ("error" in message or kind.endswith("_error")
                      or kind in {"auth_error", "quota_exceeded", "rate_limited", "queue_overflow"}):
                    raise RuntimeError("ElevenLabs transcription failed; check quota and Speech to Text access")
            if not self._closed:
                raise RuntimeError("ElevenLabs transcription disconnected")
        except asyncio.CancelledError:
            raise
        except Exception:
            self._events.put_nowait(RuntimeError("ElevenLabs transcription stopped; check connection, quota and permissions"))

    async def _work(self) -> None:
        try:
            while True:
                generation, text = await self._turns.get()
                context = self._context
                self._context = []
                prompt = "\n\n".join(context + [text])
                if self._first:
                    prompt = f"{PHONE_CONTEXT}\n\n{self._instructions}\n\n{prompt}"
                    self._first = False
                self._events.put_nowait(AgentWaiting(True))
                try:
                    answer = await self.agent.ask(prompt, call_id=self.call_id)
                    if not answer.strip():
                        raise RuntimeError("Empty OpenClaw answer")
                except asyncio.CancelledError:
                    raise
                except Exception as e:
                    # Do not retry: a failed transport may already have performed an action.
                    log.warning("direct agent turn failed (%s); not retrying", type(e).__name__)
                    answer = "OpenClaw no ha podido devolver una respuesta. Comprueba su sesión antes de repetir la petición."
                finally:
                    self._events.put_nowait(AgentWaiting(False))
                if generation == self._generation:
                    self._speech = asyncio.create_task(self._speak(answer, generation))
                    try:
                        await self._speech
                    except asyncio.CancelledError:
                        if self._closed or asyncio.current_task().cancelling():
                            raise
                    finally:
                        self._speech = None
        except asyncio.CancelledError:
            raise
        except Exception:
            self._events.put_nowait(RuntimeError("ElevenLabs speech generation failed; check Text to Speech access and voice"))

    async def _speak(self, text: str, generation: int) -> None:
        url = f"{self.tts_url}/{quote(self.voice_id, safe='')}/stream"
        async with self._http.stream("POST", url, params={"output_format": "pcm_16000"},
                                     headers={"xi-api-key": self.api_key},
                                     json={"text": text, "model_id": self.tts_model}) as response:
            if response.status_code != 200:
                raise RuntimeError(f"ElevenLabs speech failed (HTTP {response.status_code})")
            pcm = bytearray()
            self._events.put_nowait(Transcript("agent", text))
            self._events.put_nowait(TurnComplete())
            async for chunk in response.aiter_bytes(chunk_size=3200):
                if generation != self._generation or self._closed:
                    return
                pcm += chunk
                size = len(pcm) // 2 * 2  # HTTP boundaries need not align to PCM16 samples
                if size:
                    self._events.put_nowait(AudioOut(bytes(pcm[:size])))
                    del pcm[:size]
            if pcm:
                raise RuntimeError("ElevenLabs returned an incomplete PCM16 sample")

    async def events(self) -> AsyncIterator[Event]:
        while not self._closed:
            event = await self._events.get()
            if isinstance(event, Exception):
                raise event
            yield event

    async def close(self) -> None:
        self._closed = True
        if self._speech is not None:
            self._speech.cancel()
        for task in self._tasks:
            task.cancel()
        await asyncio.gather(*self._tasks, return_exceptions=True)
        if self._ws is not None:
            await self._ws.close()
            self._ws = None
        if self._http is not None:
            await self._http.aclose()
            self._http = None
