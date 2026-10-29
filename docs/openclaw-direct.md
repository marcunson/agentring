# Talk directly to OpenClaw with ElevenLabs speech

The optional `openclaw-elevenlabs` provider makes OpenClaw the conversational
agent for every turn. ElevenLabs Scribe transcribes speech, the local command
bridge sends the text to OpenClaw, and ElevenLabs Text to Speech reads OpenClaw's
reply verbatim. There is no hosted ElevenLabs Agent or second conversational LLM.

```text
iPhone ↔ agentring / LiveKit ↔ ElevenLabs Speech to Text
                               ↓ transcript
                         OpenClaw + its tools
                               ↓ answer
iPhone ← agentring / LiveKit ← ElevenLabs Text to Speech
```

The existing `elevenlabs` provider remains available and unchanged: its hosted
conversational agent decides when to delegate to OpenClaw with `consult_agent`.
Explicit `--provider` selection affects that command only. No iPhone update,
relay protocol change, public OpenClaw endpoint or additional package is needed.

## Setup

Keep a working [OpenClaw command bridge](agents.md#openclaw) in `agents.yaml`,
normally named `openclaw`, using the supplied `examples/openclaw/ask.py` adapter.
OpenClaw keeps its existing model, tools, credentials and permissions.

The ElevenLabs API key needs **Speech to Text** and **Text to Speech** access.
Access to ElevenLabs Agents alone is insufficient. Store secrets in
`$AGENTRING_HOME/.env` (mode 600), without changing the existing provider default:

```dotenv
ELEVENLABS_API_KEY=your-key
ELEVENLABS_VOICE_ID=your-voice-id
# Optional: another command agent from agents.yaml
AGENTRING_DIRECT_AGENT=openclaw
```

`ELEVENLABS_VOICE_ID` can be the voice used by the existing hosted agent. Changing
the hosted agent's voice later does not automatically change this separate
setting. A CLI `--voice` overrides it for a single command. The direct provider
uses Scribe v2 Realtime with VAD and Flash v2.5 TTS at PCM16 mono / 16 kHz; library
users can pass `tts_model` and `language` to `OpenClawDirect`.

## Choose a mode

Call the iPhone with the new mode, while the usual daemon keeps answering inbound
calls in its current mode:

```sh
agentring call "Direct OpenClaw test" --ai --provider openclaw-elevenlabs
```

To answer calls from the iPhone in direct mode, run one answering daemon with:

```sh
agentring serve --ai --provider openclaw-elevenlabs
```

Run a single answering daemon per relay. To return to the existing mode, restart
that daemon with `--provider elevenlabs`. Alternatively set
`AGENTRING_VOICE_PROVIDER` deliberately when selecting a permanent default. This
first version selects the mode on the Mac; the iPhone has no new mode selector.
Use a separate direct-mode instruction file rather than instructions telling
the hosted ElevenLabs agent to delegate to OpenClaw.

Each call gets a fresh OpenClaw session, reused across its turns. The first turn
sets the phone context and requests short, natural spoken answers. The daemon
does not resend conversation history or rewrite OpenClaw's replies. OpenClaw
handles its own tools; local agentring MCP tools and `--model` are rejected in
direct mode. Configure those in OpenClaw instead.

## Waiting, interruptions and limits

Hold music plays while OpenClaw works and stops when the turn completes. The
caller can interrupt speech; only speech synthesis is canceled. Agent turns run
in order, and an interrupted pending action is not restarted. New requests wait
for the running turn before being sent to the same OpenClaw session. A stale
reply is not spoken over a newer request.

This is a turn-based speech pipeline. End-of-speech detection and OpenClaw's
response time add latency compared with a realtime conversational agent. In
this first version, hang up using the iPhone's call button. Ending the call stops
the local bridge; it does not guarantee cancellation of work already started by
the OpenClaw gateway. Direct mode does not deliver unfinished answers as messages
after the call; the existing delegation mode retains that behavior.

Failures are not automatically retried, since an action may already have run.
The caller hears an explicit failure if OpenClaw cannot return a reply. Speech
service failures end the call with an error. Audio and text go to the respective
ElevenLabs APIs; OpenClaw receives the transcription and call context.

## Verify

```sh
cd daemon
uv run --extra voice pytest tests/test_openclaw_direct.py tests/test_hold_music.py -q
```

Tests use local WebSockets and mock HTTP to cover transcription, exact reply
speech, stable sessions, serialized actions, interrupted speech, failures without
retry, credential redaction, hold events, and coexistence with the existing mode.
Validate voice quality and end-to-end behavior with a real phone call as well.

API references: [realtime transcription](https://elevenlabs.io/docs/api-reference/speech-to-text/v-1-speech-to-text-realtime),
[streamed speech](https://elevenlabs.io/docs/api-reference/text-to-speech/stream).
