# ElevenLabs voice and local agents

ElevenLabs Agents is an alternative to Gemini Live. It handles speech recognition,
turn taking, an LLM and speech synthesis. Its LLM can call agentring's local tools,
including `consult_agent` for OpenClaw. OpenClaw answers delegated tasks; it does
not replace the conversational LLM in this integration.

For an additional mode where OpenClaw is the conversational agent and ElevenLabs
only transcribes and speaks, see [direct OpenClaw voice](openclaw-direct.md).
Select it explicitly with `--provider openclaw-elevenlabs`; the existing mode
and its hosted agent remain available.

The phone app, relay, LiveKit and push configuration stay the same. Only the daemon
connects to ElevenLabs; API keys and signed URLs never go to the phone. Audio and
conversation context are sent to ElevenLabs during an AI call.

## Set up a dedicated agent

Install the daemon with the `voice` extra. Create a restricted ElevenLabs API key
with access to ElevenAgents / Conversational AI (write access is needed for setup).
Store it in `$AGENTRING_HOME/.env`, defaulting to `~/.agentring/.env`, mode 600:

```dotenv
ELEVENLABS_API_KEY=your-key
AGENTRING_VOICE_PROVIDER=elevenlabs
```

Export the agent configuration. This does not contact ElevenLabs or require its
key. An existing `agents.yaml` adds `consult_agent` and its agent list. Include MCP
tools with `--mcp`, optionally restricted with `--tools`.

```sh
agentring elevenlabs-config --language es > elevenlabs-agent.json
# Optional: --voice <ElevenLabs voice ID> --model <supported ElevenLabs LLM ID>
```

Create a dedicated agent with that JSON using the official
[`POST /v1/convai/agents/create`](https://elevenlabs.io/docs/eleven-agents/api-reference/agents/create)
endpoint with the `xi-api-key` header. Save the returned ID in the same `.env`:

```dotenv
ELEVENLABS_AGENT_ID=agent_your-id
```

The export configures authentication, a blank first message, required overrides,
PCM16 mono at 16 kHz in both directions, transcripts, interruptions and client
tools. The call requests its greeting after the phone answers. Incorrect audio
formats fail with a setup error instead of playing at the wrong speed.
Without `--voice`/`--model`, ElevenLabs uses its defaults; tune those on the hosted
agent afterwards. Runtime `--voice` expects an ElevenLabs voice ID and `--model`
expects an ElevenLabs-supported LLM ID.

Export and update this dedicated agent again when the local tools or agent list
change. Tools are registered on the hosted agent during setup. Calls never
silently modify a hosted agent. The local allowlist rejects tools absent from
the current call.

```sh
agentring call "Prueba de ElevenLabs" --ai --provider elevenlabs
agentring serve --ai --provider elevenlabs
```

`AGENTRING_VOICE_PROVIDER` also selects the backend for `agentring mcp` calls. An
explicit CLI `--provider` takes precedence. Gemini remains the default when the
setting is absent, using its existing `GEMINI_API_KEY` configuration.

## Connect OpenClaw after the voice test

Use the [command-agent bridge](agents.md). OpenClaw needs its own working gateway,
agent and model credentials. An ElevenLabs key does not authenticate OpenClaw.

Add OpenClaw to `agents.yaml`, verify `agentring agents ask openclaw "..."`, then
export/update the ElevenLabs agent to include `consult_agent`. Restart
`agentring serve --ai` and ask it to consult OpenClaw. The bridge preserves a
session per call and delivers slow answers as a spoken update or a message after
the call. Use an absolute executable path if the daemon has a different PATH.

## Verify without provider credits

```sh
cd daemon
uv run --extra voice pytest tests/test_elevenlabs.py -q
```

Tests use mock HTTP and real local WebSockets to check authentication, audio,
interruptions, transcript corrections, ping/pong, context updates, tool results,
provider selection and setup export. A real account and phone call are still
required to validate hosted-agent configuration and voice quality. See the official
[WebSocket protocol](https://elevenlabs.io/docs/eleven-agents/api-reference/eleven-agents/websocket)
and [override settings](https://elevenlabs.io/docs/eleven-agents/customization/personalization/overrides).
