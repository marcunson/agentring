# Voice AI on calls (M3)

For ElevenLabs Agents instead of Gemini, see [ElevenLabs setup](elevenlabs.md).
Both providers use the same phone app and local tool/agent bridge.

When a call consults an agent such as OpenClaw, a quiet, locally generated hold
music loop fills the wait. Speech takes priority, and the caller can still talk
or hang up. Music follows the actual background job, including jobs that exceed
the consultation's quick-answer timeout, and stops when it finishes, fails or
is canceled. Returning agent speech clears any buffered music before playback.
Library users can disable it with `VoiceAgent(..., hold_music=False)`. No extra
audio service or phone update is required.

When a call is answered, a realtime speech-to-speech model talks to the user, can
use your tools while the call goes on, and hangs up by itself when the user says
goodbye. It works both ways: the agent calling the phone, and the phone calling
the agent ("Call agent" in the app).

Install the voice extra and give it a Gemini API key (environment or
`~/.agentring/.env`):

```bash
uv tool install './daemon[voice]'
echo GEMINI_API_KEY=... >> ~/.agentring/.env
```

## Without code

```bash
# Call the phone; the AI explains why and answers questions with your MCP tools.
agentring call "The nightly backup failed" --ai \
  --instructions @prompt.md --mcp http://127.0.0.1:8787/mcp --tools status,logs

# Answer calls from the phone with the AI.
agentring serve --ai --instructions @prompt.md --mcp http://127.0.0.1:8787/mcp
```

- `--instructions`: the system prompt (inline or `@file`). Default: a short, generic phone persona.
- `--mcp`: any MCP server over Streamable HTTP; repeat for several. `--tools` keeps only
  the listed tools: over the phone, expose only what the caller should be able to do.
- `--model` / `--voice`: Gemini Live model (default `gemini-3.8-live`) and voice (default `Charon`).
- `--agents`: an [`agents.yaml`](agents.md#agentsyaml) with your agents (the AI consults them with
  `consult_agent`) and MCP servers. Default `~/.agentring/agents.yaml` if it exists; `none` skips it.
- `call --ai --json` prints the whole result (transcript, tool calls, duration).

## As a library

```python
from agentring.relay_client import RelayClient
from agentring.voice import CallInfo, GeminiLive, Prompts, Tool, VoiceAgent

def status(service: str) -> str:
    return "up"

agent = VoiceAgent(
    lambda: GeminiLive(api_key, voice="Charon"),
    instructions="You are the on-call assistant…",   # or a (sync/async) function of CallInfo
    tools=[Tool("status", "Is a service up?", status,
                {"type": "object", "properties": {"service": {"type": "string"}}, "required": ["service"]})],
)
client = RelayClient(relay_url, api_key)
created = client.create_call("The API is down", priority="urgent")
result = await agent.run(CallInfo(created["call"]["call_id"], "The API is down"), created["join"], relay=client)
print(result.end_reason, result.transcript, result.tools)
```

Incoming calls: on each relay event (`agentring.sync.run_ws`), `accept_incoming(client, event)`
returns `(CallInfo, join)` for a call from the phone, ready for `agent.run`.

What you can plug in:

| Option | What it does |
|---|---|
| `tools` | `Tool(name, description, handler, parameters)`; sync handlers run in a thread, async ones in the loop. `mcp_tools(url, allow=[…])` turns an MCP server into tools; `Consultations(load_agents(path).agents).tool()` is `consult_agent` ([agents.md](agents.md)). A tool can find its call with `current_session()` and answer later with `session.notify(text, respond=True)`. |
| `instructions` | Text, or a function of `CallInfo` (e.g. to add fresh context when the call starts). |
| `prompts` | `Prompts(...)`: the notes the session gives the model when someone answers, joins or leaves, and the `end_call` description. Change them to change wording or language. |
| `name_of` | LiveKit identity (`device_<id>`) → the person's name, so the model greets them by name. |
| `before_tool` | `(session, call) → None \| dict \| str`: run, run with other args, or skip with that answer. The session exposes `transcript`, `partial`, `participants` and `last_user_speech_at` (e.g. "only act if the user asked in the last 45 s"). |
| `end_call_tool`, `tool_timeout_s`, `ring_timeout_s`, `max_duration_s`, `empty_room_grace_s` | Limits. A tool slower than its timeout keeps running; the model is told so. |

Behaviour: the agent joins the room while the phone rings and opens the model
session at the same time, so it greets as soon as someone answers. In group
calls everyone's audio is mixed into one input and the model is told who joins
or leaves. Talking over the model interrupts it. Tools run in their own task, so
the call keeps listening while a slow tool works. The call ends when the model
calls `end_call` (after its goodbye), everyone leaves (10 s grace for a dropped
connection), the relay says it is over, or the model's session limit is near
(Gemini: 15 min).

Gemini pricing: the Live models have a free tier (rate-limited; Google may use free-tier
data to improve its products) and a paid tier of about $0.005/min of audio in and
$0.018/min out. See https://ai.google.dev/gemini-api/docs/pricing.

## Backends

`RealtimeBackend` (voice/backend.py) is the plug point: a class that connects with
instructions + tools, sends audio/text/tool results and yields a few plain events.
Gemini Live is built in (`voice/gemini.py`); OpenAI Realtime is the next one.

## Testing

`tests/test_voice.py` covers the protocol, tools, MCP and session logic without a
phone. `tests/test_voice_live.py` runs whole calls (the AI calls a simulated phone,
and the phone calls `agentring serve --ai`) against a real relay, LiveKit and Gemini:

```bash
docker run -d --name lk -p 7880:7880 -p 7881:7881 -p 50000-50100:50000-50100/udp \
  -e "LIVEKIT_KEYS=devkey: $(openssl rand -hex 24 | tee /tmp/lk)" \
  -e 'LIVEKIT_CONFIG=rtc: {port_range_start: 50000, port_range_end: 50100, tcp_port: 7881}' \
  livekit/livekit-server:v1.13.10 --node-ip "$(ipconfig getifaddr en0)" --bind 0.0.0.0
AGENTRING_TEST_LIVEKIT_URL=ws://127.0.0.1:7880 AGENTRING_TEST_LIVEKIT_SECRET=$(cat /tmp/lk) \
GEMINI_API_KEY=... uv run --extra voice pytest tests/test_voice_live.py -s
```
