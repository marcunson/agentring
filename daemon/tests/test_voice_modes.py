"""A phone's explicit destination must never fall back to another agent."""

import asyncio
import pytest

from agentring.voice.inbound import InboundVoiceModes


class Built:
    def __init__(self):
        self.agent = object()
        self.closed = 0

    async def aclose(self):
        self.closed += 1


def test_per_call_modes_are_independent_cached_and_closed_once():
    async def run():
        normal, direct = Built(), Built()
        requests = []

        async def build(provider):
            requests.append(provider)
            return direct

        modes = InboundVoiceModes(normal, "elevenlabs", build)
        assert await modes.for_event({}) is normal.agent
        assert await modes.for_event({"voice_mode": "elevenlabs"}) is normal.agent
        assert await modes.for_event({"voice_mode": "openclaw_direct"}) is direct.agent
        assert await modes.for_event({"voice_mode": "elevenlabs"}) is normal.agent
        assert await modes.for_event({"voice_mode": "openclaw_direct"}) is direct.agent
        assert requests == ["openclaw-elevenlabs"]
        await modes.aclose()
        assert normal.closed == direct.closed == 1

    asyncio.run(run())


def test_direct_default_still_allows_explicit_hosted_agent():
    async def run():
        direct, hosted = Built(), Built()

        async def build(provider):
            assert provider == "elevenlabs"
            return hosted

        modes = InboundVoiceModes(direct, "openclaw-elevenlabs", build)
        assert await modes.for_event({"voice_mode": "openclaw_direct"}) is direct.agent
        assert await modes.for_event({"voice_mode": "elevenlabs"}) is hosted.agent
        assert await modes.for_event({}) is direct.agent
        await modes.aclose()

    asyncio.run(run())


def test_unconfigured_or_unknown_mode_is_rejected_without_fallback():
    async def run():
        requests = []

        async def build(provider):
            requests.append(provider)
            raise ValueError("not configured")

        default = Built()
        modes = InboundVoiceModes(default, "elevenlabs", build)
        with pytest.raises(ValueError, match="not configured"):
            await modes.for_event({"voice_mode": "openclaw_direct"})
        assert await modes.for_event({"voice_mode": "elevenlabs"}) is default.agent
        for invalid in [None, "", "other", {}, []]:
            with pytest.raises(ValueError, match="Unsupported"):
                await modes.for_event({"voice_mode": invalid})
        assert requests == ["openclaw-elevenlabs"]
        await modes.aclose()

    asyncio.run(run())
