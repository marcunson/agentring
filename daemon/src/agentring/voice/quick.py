"""A ready-made voice agent from a few options (what `agentring call --ai` and `serve --ai` use)."""

from __future__ import annotations

import asyncio
from dataclasses import dataclass
from pathlib import Path

from .agents import AgentsConfig, Consultations
from .gemini import DEFAULT_MODEL, DEFAULT_VOICE, GeminiLive
from .session import VoiceAgent
from .tools import McpClient, Tool, mcp_tools

DEFAULT_INSTRUCTIONS = (
    "You are the user's AI agent talking to them on the phone. Speak like a person on a call: short, "
    "natural sentences, one idea at a time, in the user's language. Never read out ids, links or paths. "
    "Never claim you did or checked something unless a tool told you so in this call."
)


MISSED_CALL = "Missed call: {reason}"


def missed_call_message(relay, call_id: str, reason: str, details: str | None = None) -> str:
    """M4 fallback: what the call was about, as a message the user can answer. Returns msg_id."""
    text = MISSED_CALL.format(reason=reason) + (f"\n\n{details}" if details else "")
    return relay.post_message(text[:4000], reply_to=call_id)["msg_id"]


def read_instructions(value: str | None) -> str:
    """Inline text, or @path to read it from a file."""
    if not value:
        return DEFAULT_INSTRUCTIONS
    if value.startswith("@"):
        return Path(value[1:]).expanduser().read_text(encoding="utf-8")
    return value


@dataclass
class BuiltAgent:
    agent: VoiceAgent
    mcp_clients: list[McpClient]
    consultations: Consultations | None = None

    async def aclose(self, *, wait_answers_s: float | None = 0) -> None:
        """Closes the MCP clients. Agents' answers still on their way get `wait_answers_s`
        (None = as long as they take) to arrive as messages; then they are stopped."""
        if self.consultations is not None:
            if wait_answers_s != 0:
                await self.consultations.drain(wait_answers_s)
            await self.consultations.aclose()
        for c in self.mcp_clients:
            await c.aclose()


async def build_agent(
    api_key: str,
    *,
    instructions: str | None = None,
    mcp: list[str] | None = None,
    allow: list[str] | None = None,
    agents: AgentsConfig | None = None,
    model: str | None = None,
    voice: str | None = None,
    provider: str = "gemini",
    agent_id: str | None = None,
    voice_id: str | None = None,
    direct_agent: str = "openclaw",
) -> BuiltAgent:
    """A voice provider with the tools of the given MCP servers (only `allow` if given) and of
    agents.yaml (its MCP servers, and `consult_agent` for its agents). Close it when done."""
    if provider == "openclaw-elevenlabs":
        from .direct import OpenClawDirect

        selected = next((a for a in (agents.agents if agents else []) if a.name == direct_agent), None)
        if selected is None:
            raise ValueError(f"Direct mode needs the {direct_agent!r} command agent in agents.yaml")
        if not (voice or voice_id):
            raise ValueError("Direct mode needs ELEVENLABS_VOICE_ID or --voice; see docs/openclaw-direct.md")
        if model:
            raise ValueError("Direct mode uses OpenClaw's model settings; omit --model")
        if mcp or (agents and agents.mcp):
            raise ValueError("Direct mode uses OpenClaw's own tools; configure MCP servers in OpenClaw")
        factory = lambda: OpenClawDirect(api_key, voice or voice_id, selected)
        return BuiltAgent(VoiceAgent(factory, read_instructions(instructions), end_call_tool=False), [])
    if provider == "gemini":
        factory = lambda: GeminiLive(api_key, model=model or DEFAULT_MODEL, voice=voice or DEFAULT_VOICE)
    elif provider == "elevenlabs":
        from .elevenlabs import ElevenLabs

        if not agent_id:
            raise ValueError("ElevenLabs needs an agent_id")
        factory = lambda: ElevenLabs(api_key, agent_id, model=model, voice=voice)
    else:
        raise ValueError(f"Unknown voice provider: {provider}")
    text = read_instructions(instructions)
    built = BuiltAgent(None, [])  # type: ignore[arg-type]
    tools: list[Tool] = []
    servers = [(url, allow, None) for url in mcp or []]
    servers += [(m.url, m.tools, m.headers) for m in (agents.mcp if agents else [])]
    try:
        for url, only, headers in servers:
            found, client = await mcp_tools(url, allow=only, headers=headers)
            tools += found
            built.mcp_clients.append(client)
    except BaseException:
        await asyncio.shield(built.aclose())
        raise
    if agents and agents.agents:
        built.consultations = Consultations(agents.agents)
        tools.append(built.consultations.tool())
    built.agent = VoiceAgent(factory, text, tools)
    return built
