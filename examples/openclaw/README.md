# OpenClaw + agentring

Two things to set up: your OpenClaw assistant can reach you (MCP server + skill), and
you can reach it from a call (an agent in `agents.yaml`). Recipes for other harnesses:
[docs/agents.md](../../docs/agents.md#recipes-by-harness).

## OpenClaw reaches you

```bash
agentring init --relay https://relay.example.com --api-key ak_...
agentring pair                                   # scan the QR with the app
openclaw mcp set agentring '{"command":"agentring","args":["mcp"]}'
cp -r ../../skills/agentring ~/.openclaw/skills/  # when to message and when to call
```

Calls need the voice extra and a voice provider: Gemini (free tier available at
https://aistudio.google.com/apikey), or [ElevenLabs Agents](../../docs/elevenlabs.md).
For Gemini:

```bash
uv tool install 'agentring[voice]'
echo GEMINI_API_KEY=... >> ~/.agentring/.env
```

Then, for example: *"Check my inbox every hour; if something is urgent, call me."*

## You reach OpenClaw by phone

To let the voice assistant consult your existing OpenClaw gateway, add this to
`$AGENTRING_HOME/agents.yaml` (normally `~/.agentring/agents.yaml`):

```yaml
agents:
  openclaw:
    description: Ask my OpenClaw assistant to answer questions or carry out requested tasks.
    command: [/absolute/path/to/python3, /absolute/path/to/agentring/examples/openclaw/ask.py]
    timeout_s: 130
    env:
      AGENTRING_OPENCLAW_BIN: /absolute/path/to/openclaw
      AGENTRING_OPENCLAW_AGENT: main
```

The adapter reads the task from stdin, passes it through a private temporary file
and extracts only assistant text from the CLI JSON response. It uses a separate session for each call, preserving context
between questions in that call. It never passes `--deliver`, changes approval
settings or retries a task automatically after an uncertain result. OpenClaw
keeps its existing model credentials and tool permissions.

Keep the OpenClaw gateway running. Change `main` in the configuration to use
another of your agents. The adapter requires an OpenClaw CLI with `--message-file`
and `--session-key` support.

Verify `agentring agents ask openclaw "Reply briefly without using tools"`, then
follow [ElevenLabs setup](../../docs/elevenlabs.md) to export/update the dedicated
hosted agent with the `consult_agent` client tool and restart `agentring serve --ai`.

On the call: *"Ask OpenClaw to remind me to call the bank at five."* The voice AI
asks it, tells you it's on it, and reads you the answer when it comes. If you've
already hung up, the answer arrives as a message.

The voice AI acts on what it hears: give the phone only the agents and channels you'd
accept from someone holding it.
