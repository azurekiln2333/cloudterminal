# Windows client and sidecar contract

## Scope and ownership

The Windows connection assistant (`apps/cloudterminal_windows`, Flutter, MD3)
does **not** re-implement the relay client. It spawns the Node agent in sidecar
mode and talks to it over a loopback-only JSON-line socket.

```
Flutter (apps/cloudterminal_windows)          Node sidecar (server/src/agent/sidecar.ts)
  SidecarClient  ──127.0.0.1:<random port>──▶  RelayLink ──wss──▶ relay
  AssistantController                          AgentCore / HerdrBridge
                                               tool-probe / tool-streams
```

- `server/src/agent/sidecar.ts` owns the protocol, the relay link and tool
  sessions. It prints `{"type":"listening","port":N}` as its first stdout line,
  then serves the socket.
- `apps/.../lib/engine/sidecar_client.dart` owns the client socket and framing.
- `server/src/agent/tool-probe.ts` discovers tools; `tool-streams.ts` owns
  bindings; `sidecar-helpers.ts` holds the pure framing/summary helpers.
- The socket binds `127.0.0.1` only. It is never exposed to the LAN.

## Framing

One JSON object per line, both directions, UTF-8. A partial line is buffered
(`createLineDecoder`); a non-JSON line is skipped rather than dropping the
connection.

Client → sidecar: `pair_code`, `reset_pairing`, `tool_probe`,
`tool_start_managed {kind,prompt?}`, `tool_bind {id}`, `tool_unbind {id}`,
`tool_input {id,text}`, `tool_poll_interval {id,intervalMs}`,
`set_relay {url?,key?,clear?}`.

Sidecar → client: `snapshot`, `pair_code`, `stream_event`, `managed_started`,
`error`. `snapshot` carries `relayOnline`, `relayUrl`, `retries`, `lastError`,
`tools[]` and `bindings[]`.

## Bindings and the honesty rule

Every binding declares its `origin`:

| origin | Meaning | UI may call it "live"? |
| --- | --- | --- |
| `managed-stream` | A process we started (Claude `--output-format stream-json`) | Yes |
| `daemon-history` | A snapshot read of an existing session (`claude agents`/`logs`) | No |
| `pane-poll` | Repeated screen reads (Herdr `pane read`) | No — show the interval |

Never label a `pane-poll` or `daemon-history` binding as a real-time stream.
`stream_event.eventKind === 'snapshot'` replaces the buffer; any other kind
appends. This distinction is asserted in tests on both sides.

## Tool capabilities (measured 2026-10-12)

| Tool | Managed stream | Read-only | Unsupported |
| --- | --- | --- | --- |
| Codex | app-server JSON-RPC (`ThreadStart`/`TurnStart` + deltas) | `ThreadList`/`ThreadRead` | reading a foreign TUI's stdout |
| Claude Code | `-p --output-format stream-json` | `claude agents --json` + `logs` | attaching to an interactive TUI |
| Herdr | (control via the relay bridge) | `pane read` (polled) | a change feed (none exists) |

It is impossible to read the stdout of an arbitrary already-running process;
the client must never imply otherwise.

## Bootstrap and pairing

`server/src/agent/bootstrap.ts` reads an optional `bootstrap.json` as the
**lowest-priority** relay source (CLI flag → env → `agent.json` → bootstrap →
none). A malformed file yields an actionable Chinese error, never a throw.

`server/src/shared/pairing.ts` (mirrored by
`apps/.../lib/models/pairing_uri.dart`) encodes
`cloudterminal://pair?relay=<ws(s) url>&code=XXXXXXXX&v=1`. It carries the relay
address and a one-time code and **never** a long-lived secret. The phone still
exchanges the code for credentials through the relay.

## Non-regression

`--sidecar` is additive: without it `main.ts` behaves exactly as before. The
sidecar is the only place that starts tool processes, and it only stops
processes it started itself. `close()` on the streams clears pollers and kills
only those children.

## Tests

`server/test/sidecar.test.ts` (framing + helpers), `bootstrap.test.ts`,
`pairing.test.ts`, and the Dart side
`apps/cloudterminal_windows/test/sidecar_ipc_test.dart` which starts the REAL
sidecar and asserts snapshot/probe/pair-code over the socket.
