# Design: Remote Claude Code console

## Topology

```
 Phone app (Flutter)  ──wss──▶  Relay (public VPS)  ◀──wss──  Agent (PC, Node)
                                                                  │
                                                                  ▼
                                                   Claude Agent SDK → claude CLI
```

- The agent dials **out** to the relay, so the PC needs no inbound port, no
  static IP and no router config.
- The relay is a dumb, authenticated forwarder. It does not parse agent
  payloads; it only routes frames between one agent and N clients.
- `agent --local-relay` runs relay + agent in one process for LAN use or for
  exposing via Tailscale / Cloudflare Tunnel instead of a VPS.

### Why the Agent SDK and not PTY scraping

Scraping the interactive TUI gives unstructured ANSI output and no reliable
hook for permission prompts. The SDK (`@anthropic-ai/claude-agent-sdk`) spawns
the same `claude` CLI in stream-json mode and gives us:

- typed message stream (assistant text / thinking / tool_use / tool_result /
  result with cost),
- `canUseTool` callback that can stay pending until the phone answers,
- streaming input (follow-up messages mid-session), `interrupt()`,
  `setPermissionMode()`, `resume` of past sessions, `listSessions()`.

Sessions still load user/project settings, CLAUDE.md and hooks (default
`settingSources`), so behaviour matches the terminal.

Note: Claude Code also ships an official `--remote-control` mode tied to the
claude.ai apps. This project is the self-hosted alternative.

## Relay protocol (`/ws`)

First frame from every socket must be `hello` within 10 s, otherwise closed.

| Direction | Frame |
| --- | --- |
| agent → relay | `{t:"hello", role:"agent", agentId, secretHash, relayKey?, name}` |
| client → relay | `{t:"hello", role:"client", agentId, secret}` |
| relay → any | `{t:"hello_ok", clientId?}` / `{t:"error", code, message}` then close |
| relay → client | `{t:"presence", online:boolean, name?}` |
| relay → agent | `{t:"client_joined"\|"client_left", clientId}` |
| client → relay → agent | `{t:"msg", data}` → agent receives `{t:"msg", clientId, data}` |
| agent → relay → client | `{t:"msg", data, to?}` → broadcast, or only to `to` |

Auth: relay stores `secretHash = sha256(secret)` supplied by the agent and
compares `sha256(client.secret)` with `timingSafeEqual`. A re-registering
agent with a different hash for a live `agentId` is rejected. Failed client
auth is rate limited per IP. `relayKey` (env `RELAY_KEY`) gates who may
register agents at all. Frames are capped (4 MiB) and sockets heartbeated.

## Agent protocol (inside `data`)

Client → agent (`id` correlates replies):

- `info` → `{kind:"info", host, platform, defaultCwd, allowBypass}`
- `list_sessions` → `{kind:"sessions", sessions:[SessionInfo]}`
- `list_history {cwd?}` → `{kind:"history", items:[{sessionId, summary, cwd, lastModified}]}`
- `list_dir {path}` → `{kind:"dir", path, parent, entries:[name]}` (directories only)
- `create_session {cwd, prompt?, mode?, model?, resume?}` → `{kind:"session_created", session}`
- `subscribe {sessionId, afterSeq}` → backlog as `events` then live `event`s
- `unsubscribe {sessionId}`
- `send {sessionId, text}`
- `interrupt {sessionId}`
- `permission {sessionId, requestId, decision:"allow"|"allow_always"|"deny", message?, answers?}`
- `set_mode {sessionId, mode}`
- `close_session {sessionId}`

Agent → client: `ack {id}`, `error {id?, message}`, `session {session}`
(any state change, broadcast), `events {sessionId, events}`, `event {sessionId, event}`,
`delta {sessionId, text}` (ephemeral streaming text, not stored).

### Normalized events (`seq` increasing per session)

`user`, `assistant` (text), `thinking`, `tool_use {toolUseId, name, input, summary}`,
`tool_result {toolUseId, content, isError}`, `permission_request {requestId,
toolName, title, input, suggestions, question?}`, `permission_resolved
{requestId, decision}`, `result {subtype, costUsd, durationMs, turns, text}`,
`system {text}`, `error {text}`.

Backlog: last 2000 events per session, long strings truncated to 8 KiB.
A reconnecting client sends `subscribe` with the last `seq` it saw.

### Session state

`{id, title, cwd, status:"starting"|"running"|"waiting"|"idle"|"error"|"closed",
mode, model?, claudeSessionId?, createdAt, updatedAt, costUsd, pending, lastSeq}`

## Security

- Whoever holds the pairing secret can run Claude with tools on the PC —
  treat the pairing link like an SSH key.
- `bypassPermissions` is refused unless the agent runs with `--allow-bypass`.
- `list_dir` / `create_session` are limited to `--root` directories
  (default: home directory).
- Internet deployments must terminate TLS (Caddy/Nginx) in front of the relay.
- Not in v1: end-to-end encryption (relay operator can read traffic).

## App

Flutter, Material 3, theme lifted from terminax (`ColorScheme.fromSeed`,
surfaceContainer app bars, 28 px bottom sheets, floating snackbars). Plain
`dart:io` WebSocket behind a small transport interface (testable, no plugin).

Screens: Pair → Home (connection + sessions + history) → Session (event
stream, permission cards pinned above composer, mode menu, interrupt).
Reconnect with exponential backoff; resubscribe with `afterSeq`.
