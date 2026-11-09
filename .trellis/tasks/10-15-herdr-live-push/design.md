# Design — Herdr live push

## Boundary

```
desktop herdr server ──socket (newline JSON)──┐
                                             │ events.subscribe
                                             ▼
                                   HerdrSocketClient           (new, agent)
                                             │ pane.output_changed{pane,revision}
                                             ▼
                                   HerdrLivePush               (new, agent)
                                     ├─ per-pane coalescing
                                     ├─ pane read (existing bridge)
                                     └─ prefix-delta construction
                                             │ EventEmitter
                                             ▼
                                     AgentCore.addEmitter ──► relay ──► phone
                                             │
                                             ▼
                                HerdrController (app) applies
                                ├─ terminal bytes  → SessionView.terminal.write
                                └─ listing patches → _tabs/_panes/_workspaces
```

Two new agent-side modules keep `herdr.ts` as the only thing that spawns the
CLI, and keep the socket client free of CLI knowledge:

| File | Owns |
| --- | --- |
| `server/src/agent/herdr-socket.ts` | Endpoint discovery, newline-JSON framing, reconnect/backoff, `events.subscribe`, typed event callbacks, and the short `pane.read` used for content |
| `server/src/agent/herdr-live.ts` | Subscription choice, structure-event patch construction, per-pane content reads with coalescing, prefix-delta, emitting to clients |
| `server/src/agent/herdr.ts` | Unchanged CLI surface; still the control path (`*_act`) and the resilience fallback |

## Socket client

Endpoint comes from `herdr status --json`'s `server.socket`. On Windows the path
is a real file that the server also exposes as the pipe
`\\.\pipe\<absolute socket path>`; on POSIX it is a Unix socket. So:

```
connect(target) where target =
  win32 ? `\\\\.\\pipe\\${socketPath}` : socketPath
```

Framing: one JSON object per line in both directions. Requests carry an `id`
(an incrementing counter) so the `ping` reply can be matched. An empty `id` is
rejected by the server (`missing field id`), so `id` is never omitted.

`events.subscribe` ack: the server replies
`{"id":…,"result":{"type":"subscription_started"}}`. **Crucially it replies
only when every subscription entry is valid**: one unknown type (for example
`pane.output_changed`, which is not in the `Subscription` union) makes the server
accept the frame and then stay silent forever — no ack, no events. So the client
must treat "no `subscription_started` within the timeout" as a **failure**, not
as "subscribed and quiet", and re-subscribe with a reduced/validated list.

Framing details that the first probe got wrong:

- Subscription entries use the **dot** form (`tab.created`); the delivered event
  name uses **underscores** (`tab_created`).
- Events arrive as their own frames: `{"event":"tab_created", "data":{…}}`.
- An event frame has no `id`; a reply has one. That is the dispatch rule.

Reconnect: exponential backoff with jitter, capped, and **re-subscribe on every
reconnect** (the server keeps no subscription across a connection). A drop clears
nothing on the server side; the next `herdr_*` read is unaffected.

A long-lived connection must not be shared with `pane.read`: server replies to a
`pane.read` and then closes that connection. Content reads therefore use their
own short-lived connection.

## What triggers a content push (measured)

The edge that was hoped for does not exist:

| Event | Verdict |
| --- | --- |
| `pane.output_changed` | **Not a subscription type.** Subscribing to it poisons the whole subscription into silence |
| `pane.updated` | Fires for structure, **never** for content |
| `pane.output_matched` | Fires on **matching** output only (~59 ms). Cannot be the general trigger |
| `pane.scroll_changed` | Not observed |

So content uses the **third fallback the user authorised**: with a pane selected,
the agent reads just that pane every 100–200 ms **over the socket** (`pane.read`),
not by spawning the CLI. That is one short request per tick on an existing
connection, and the measured socket read is sub-millisecond for a 40-line read.

Structure changes take the **true edge** path: the event payload already carries
the tab/pane/workspace object, so no read happens at all.

### Comparison of what was available

| Option | Latency | Cost | Chosen |
| --- | --- | --- | --- |
| `pane.output_matched` with a catch-all regex | ~59 ms but only on a match | Misses any output that does not match | ✗ |
| Socket `pane.read` on a 150 ms tick | ≤ ~150 ms + read | One request per tick per selected pane, connection reuse | ✓ |
| CLI `pane read` per tick | ≤ interval + ~30 ms spawn | A process spawn per tick | ✗ (kept as fallback) |

## Coalescing (the latency-critical part)

Per pane, one of three states:

```
idle        ── event ──► reading (read immediately, remember revision)
reading     ── event ──► reading + dirty=true, revision=newest   (no new read)
reading     ── read ok ──► emit; if dirty → read again at once, dirty=false
                          else → idle
```

Properties that matter:
- **No debounce / no timer.** The first event starts a read synchronously.
- **Bounded concurrency**: at most one in-flight read per pane, so a burst of
  events cannot fan out into N CLI spawns.
- **Lossless**: the newest revision is always eventually read, even if it arrived
  mid-read.
- Events for panes other than the selected one skip the read entirely and only
  refresh structure (R2).

## Delta construction

Keep `lastText` per pane (what the phone was last told).

```
commonPrefix(a, b) = longest i where a[0..i) == b[0..i)
```

- `b` starts with `a` → append case → `{reset: false, prefix: a.length, chunk: b.slice(a.length)}`.
- otherwise → `{reset: true, prefix: 0, chunk: b}`.
- `a == b` → send nothing at all (R3/R4 requirement 4).

The receiver (`SessionView`/`HerdrController`) keeps the same `lastText`, so it
can validate `prefix` and fall back to a full replace if it disagrees — this is
what makes a missed message harmless rather than corrupting.

Why prefix deltas and not a real line diff: the payload is a *terminal screen*,
where the common case is "the tail grew" (command output) and the pathological
case is "everything repainted" (TUI redraw). Those are exactly the two branches
above; a general diff would cost more than it saves on a screen that is usually
≤ 200 lines.

## Protocol (additive, `PROTOCOL_VERSION` unchanged)

Request:
- `herdr_watch { paneId?: string }` — select the pane whose output is streamed.
  `paneId: null` clears the selection (the rows still get structure pushes).
  Validated with the existing pane-id rule.

Replies (unsolicited pushes, no `id` correlation needed, so they are `kind`-only
and tolerate unknown kinds on older clients):
- `{ kind: 'herdr_pane_output', paneId, revision, reset, prefix, chunk }`
- `{ kind: 'herdr_structure', workspaces?, agent? , tabs?, panes?, workspaceId? }`
  — only the parts that changed, so the phone patches instead of replacing.

Both are also expressible as ordinary `AgentMessage`s so the existing relay
passthrough needs no change.

## App side

- `RemoteController` learns the two push kinds and forwards them to
  `HerdrController`.
- `HerdrController.applyPaneOutput(...)`: validates `prefix` against its stored
  text, then emits the new bytes to the screen that renders that pane.
- `HerdrController.applyStructure(...)`: patches `_workspaces`/`_agents`/
  `_tabs`/`_panes` and notifies **only if something changed** (same quiet rule as
  the watchdog, so a push cannot make `pumpAndSettle` spin).
- `SessionScreen` sends `herdr_watch { paneId: <selected pane> }` on open and on
  pane switch, and `herdr_watch { paneId: null }` on dispose.
- Watchdog default becomes 12 s (was 3 s) and its documented role changes from
  "how changes are noticed" to "the net under a stream that cannot ack".

## Tradeoffs

| Choice | Cost | Why accepted |
| --- | --- | --- |
| Socket API instead of CLI-only | A second, undocumented-but-schema'd surface | It is the only source of edges; the CLI is poll-only. `herdr api schema --json` gives the full request/response contract, versioned as protocol 22 |
| `pane read` still fetches a full screen per event | One CLI spawn per change | Herdr exposes no byte stream; the read is the only way to get content, and coalescing keeps the rate at the event rate |
| Coalesce instead of debounce | A single read may be followed by one extra read | Debounce adds a fixed delay by construction, which the user explicitly rejected; coalescing adds none |
| Prefix delta with a reset escape hatch | Two code paths in the receiver | Append is the hot path; a repaint must not be turned into an unreadable splice |
| Keep the watchdog | Still a timer | The subscribe has no ack; without a net a silently dead subscription would freeze the rows forever |

## Rollback

`server/src/agent/herdr-live.ts` + `herdr-socket.ts` are new files; the wiring in
`main.ts`/`core.ts`/`protocol.ts` is additive. Reverting the two files and the
additive branches restores the previous request/response behaviour exactly. The
app-side push handling is additive too: unknown push kinds are ignored, and the
watchdog still works at the old interval.
