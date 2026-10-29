# agentring daemon

The agent side of [agentring](https://github.com/mutonby/agentring): the `agentring`
CLI, the MCP server (`agentring mcp`) and the voice AI for calls. It lets your AI
agents message and call your phone, and lets you call them back.

```bash
uv tool install 'agentring[voice]'   # or, from a checkout: uv tool install './daemon[voice]'
agentring init --relay https://relay.example.com --api-key ak_...
agentring pair                       # scan the QR with the Android app
agentring msg "hola"
agentring call "Testing agentring" --ai   # Gemini by default; see docs/elevenlabs.md for --provider elevenlabs
claude mcp add agentring -- agentring mcp
```

You need your own relay (self-hosted, Docker compose) and the Android app. See the
[setup guide](https://github.com/mutonby/agentring/blob/main/docs/setup.md)
and [connecting agents](https://github.com/mutonby/agentring/blob/main/docs/agents.md).
