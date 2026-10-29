"""Shared CLI/MCP provider selection without importing the audio SDK."""

from ..config import secret


def voice_options(provider: str | None = None) -> dict[str, str]:
    provider = (provider or secret("AGENTRING_VOICE_PROVIDER") or "gemini").strip().lower()
    if provider not in ("gemini", "elevenlabs"):
        raise ValueError("voice provider must be gemini or elevenlabs")
    name = "GEMINI_API_KEY" if provider == "gemini" else "ELEVENLABS_API_KEY"
    key = secret(name)
    if not key:
        raise ValueError(f"calls need {name} (environment or ~/.agentring/.env)")
    options = {"api_key": key, "provider": provider}
    if provider == "elevenlabs":
        agent = secret("ELEVENLABS_AGENT_ID")
        if not agent:
            raise ValueError("ElevenLabs calls need ELEVENLABS_AGENT_ID; see docs/elevenlabs.md")
        options["agent_id"] = agent
    return options
