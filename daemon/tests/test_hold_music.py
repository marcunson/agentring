"""Waiting audio must follow the actual job and yield immediately to speech."""

import asyncio
import time

import pytest

pytest.importorskip("livekit")
import numpy as np

from agentring.voice import CallInfo, ToolCall, VoiceAgent
from agentring.voice.agents import Consultations
from agentring.voice.backend import AudioOut, Interrupted, Transcript
from agentring.voice.hold_music import HoldMusic
from agentring.voice.session import CallSession


class Backend:
    input_rate, output_rate, max_session_s = 16000, 24000, None

    async def close(self):
        pass


def session(*, tools=(), **kwargs):
    return CallSession(VoiceAgent(Backend, "brief", tools=tools, **kwargs), CallInfo("test"))


async def close(s):
    await s.stop(end_call=False)
    await s.source.aclose()


@pytest.mark.parametrize("rate", [16000, 24000, 48000])
def test_original_loop_is_quiet_pcm_and_can_repeat(rate):
    music = HoldMusic(rate)
    pcm = music.read(rate * 17)
    samples = np.frombuffer(pcm, dtype="<i2").astype(np.float64)
    assert len(pcm) == rate * 17 * 2
    assert 100 < np.sqrt(np.mean(samples ** 2)) < 1500
    assert np.max(np.abs(samples)) <= 2400
    assert samples[0] == 0
    # Two complete repeats match after the initial fade; no missing wrap samples.
    assert np.array_equal(samples[rate:rate * 8], samples[rate * 9:rate * 16])


def test_speech_has_priority_and_last_job_stops_music(monkeypatch):
    clock = [100.0]
    monkeypatch.setattr(time, "time", lambda: clock[0])

    async def run():
        s = session()
        a, b = object(), object()
        cleared = []
        monkeypatch.setattr(s.source, "clear_queue", lambda: cleared.append(True))
        try:
            s.start_hold(a); s.start_hold(b)
            assert not any(s._next_audio_frame())  # no music for quick tasks
            clock[0] += 1
            assert any(s._next_audio_frame())
            s.end_hold(a)
            assert any(s._next_audio_frame())  # another agent is still working
            voice = b"\x01\x00" * (s._frame // 2)
            s.handle_event(AudioOut(voice))
            assert not s._playing_hold
            assert len(cleared) == 1  # queued music cannot obscure the returning voice
            assert s._next_audio_frame() == voice
            assert not any(s._next_audio_frame())  # allow the current sentence to finish
            clock[0] += 1
            assert any(s._next_audio_frame())
            s.end_hold(b)
            assert len(cleared) == 2
            assert not any(s._next_audio_frame())
        finally:
            await close(s)

    asyncio.run(run())


def test_user_can_interrupt_waiting_audio_and_hang_up(monkeypatch):
    clock = [100.0]
    monkeypatch.setattr(time, "time", lambda: clock[0])

    async def run():
        s = session()
        try:
            s.start_hold(object()); clock[0] += 1
            assert any(s._next_audio_frame())
            s.handle_event(Interrupted())
            assert not any(s._next_audio_frame())
            clock[0] += 2
            assert any(s._next_audio_frame())
            s.handle_event(Transcript("user", "Are you still there?"))
            assert not any(s._next_audio_frame())
            clock[0] += 2
            assert any(s._next_audio_frame())
            s.hang_up()
            assert not s._hold_tokens and not any(s._next_audio_frame())
        finally:
            await close(s)

    asyncio.run(run())


def test_waiting_audio_can_be_disabled():
    async def run():
        s = session(hold_music=False)
        try:
            s.start_hold(object())
            assert not s._hold_tokens and not any(s._next_audio_frame())
        finally:
            await close(s)

    asyncio.run(run())


class Agent:
    name, description = "openclaw", "Test agent"

    def __init__(self):
        self.started = asyncio.Event()
        self.release = asyncio.Event()
        self.fail = False

    async def ask(self, task, *, call_id=None):
        self.started.set()
        await self.release.wait()
        if self.fail:
            raise RuntimeError("agent failed")
        return "Actual answer"


@pytest.mark.parametrize("outcome", ["answer", "error", "cancel"])
def test_hold_survives_soft_timeout_and_releases_for_all_job_outcomes(outcome):
    async def run():
        a = Agent()
        consultations = Consultations([a], answer_within_s=0.02)
        s = session(tools=[consultations.tool()])
        try:
            task = asyncio.create_task(s.run_tool(ToolCall("1", "consult_agent", {"agent": "openclaw", "task": "test"})))
            await asyncio.wait_for(a.started.wait(), 1)
            assert len(s._hold_tokens) == 1
            result = await task
            assert "working on it" in result
            assert len(s._hold_tokens) == 1  # do not stop at the 20-second status result
            if outcome == "cancel":
                await consultations.aclose()
            else:
                a.fail = outcome == "error"
                a.release.set()
                await consultations.drain(1)
                text, respond = s._notes.get_nowait()
                assert respond
                assert ("Actual answer" if outcome == "answer" else "agent failed") in text
            assert not s._hold_tokens
            assert not any(s._next_audio_frame())
        finally:
            await consultations.aclose()
            await close(s)

    asyncio.run(run())


def test_ending_call_clears_music_while_agent_finishes_later():
    async def run():
        a = Agent()
        consultations = Consultations([a], answer_within_s=0.01)
        s = session(tools=[consultations.tool()])
        try:
            await s.run_tool(ToolCall("1", "consult_agent", {"agent": "openclaw", "task": "test"}))
            assert s._hold_tokens
            s.finish("hung_up")
            assert not s._hold_tokens and not any(s._next_audio_frame())
            a.release.set()
            await consultations.drain(1)
            assert s._notes.empty()
        finally:
            await consultations.aclose()
            await close(s)

    asyncio.run(run())
