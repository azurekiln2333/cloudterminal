# Implement — Herdr live push

Verification commands (repo root unless stated):

```powershell
cd server; npm test
cd ..; flutter analyze
flutter test
```

Latency measurement is a separate, explicit step (F/G) and its numbers go into
`notes.md`.

---

## A. Socket client (`server/src/agent/herdr-socket.ts`)

- [ ] A1. `socketTarget(socketPath)` — `\\.\pipe\<path>` on win32, the path
      itself elsewhere. Unit-tested for both branches (pure function).
- [ ] A2. Newline-JSON line splitter that tolerates a partial line and multiple
      lines per chunk. Unit-test with split/merged chunks.
- [ ] A3. `connect()` — `net.connect`, send `ping` with a non-empty `id`, resolve
      on `pong`, reject on the first `{"error":…}` or timeout. Never omits `id`
      (the server rejects a missing `id`).
- [ ] A4. `subscribe(types)` — write `events.subscribe` with the subscription
      list; do **not** wait for a reply (there is none). Expose `onEvent(cb)`.
- [ ] A5. Reconnect with capped exponential backoff + jitter; re-subscribe on
      every successful reconnect. `close()` stops the loop and is idempotent.
- [ ] A6. Dispatch `{"id":…}` replies to their pending request and
      event-shaped frames to `onEvent`. Unknown event types are ignored, not
      thrown.

## B. Live push (`server/src/agent/herdr-live.ts`)

- [ ] B1. Subscription list: `pane.output_changed`, `workspace.updated`,
      `workspace.focused`, `tab.created`, `tab.closed`, `tab.focused`,
      `tab.renamed`, `pane.created`, `pane.closed`, `pane.updated`,
      `pane.focused`, `pane.moved`, `pane.exited`, `pane.agent_status_changed`.
- [ ] B2. `selectPane(paneId | null)` validates the id through the existing
      `requirePaneId` and resets per-pane state on change.
- [ ] B3. Per-pane coalescing state machine exactly as `design.md` describes:
      first event reads immediately; further events set `dirty` + newest
      revision; on completion, read again at once iff dirty. No timers.
- [ ] B4. On a successful read, skip the emit when the text is unchanged.
- [ ] B5. Delta: append ⇒ `{reset:false, prefix:old.length, chunk:new.slice(old.length)}`;
      otherwise `{reset:true, prefix:0, chunk:new}`. Keep `lastText` per pane.
- [ ] B6. Structure events push only the affected listing:
      tab/pane events ⇒ that workspace's tabs+panes; workspace/agent events ⇒
      workspaces+agents. Reuse `HerdrBridge.tabs/panes/workspaces/agents`.
- [ ] B7. A socket drop clears per-pane in-flight bookkeeping and marks the push
      inactive; it must not emit a partial screen.
- [ ] B8. `close()` awaits the socket close and is safe to call twice.

## C. Protocol (`server/src/shared/protocol.ts`)

- [ ] C1. Add request `herdr_watch { paneId?: string }`.
- [ ] C2. Add messages `herdr_pane_output { paneId, revision, reset, prefix, chunk }`
      and `herdr_structure { workspaceId?, workspaces?, agents?, tabs?, panes? }`.
- [ ] C3. Keep everything additive; `PROTOCOL_VERSION` unchanged.

## D. Wiring (`core.ts`, `main.ts`)

- [ ] D1. `AgentCoreOptions` gains `herdrLive?: HerdrLivePush`.
- [ ] D2. Route `herdr_watch` to `selectPane`, per-client. Track the selected
      pane per client so two phones do not fight: the union of requested panes is
      what gets read.
- [ ] D3. `herdrLive` emits into `AgentCore.fanout` (all links), so both the LAN
      and public entries carry the push.
- [ ] D4. `main.ts` constructs `HerdrLivePush` with the bridge + logger when Herdr
      is enabled, and closes it on shutdown. No new CLI flag; `--no-herdr` covers
      it.

## E. App (`lib/`)

- [ ] E1. `RemoteController`: handle `herdr_pane_output` and `herdr_structure`
      push kinds; forward to a sink the `HerdrController` registers. Unknown push
      kinds are ignored.
- [ ] E2. `HerdrController.applyPaneOutput`: validate `prefix` against the stored
      text; on mismatch fall back to a full replace. Expose the bytes so the
      terminal view can write them.
- [ ] E3. `HerdrController.applyStructure`: patch caches; notify **only if
      changed** (reuse the signature helpers from the watchdog work).
- [ ] E4. `HerdrController.watchPane(paneId | null)` sends `herdr_watch`.
- [ ] E5. `SessionScreen`: watch the selected pane on open and on chip tap; clear
      on dispose.
- [ ] E6. Watchdog default 3 s → 12 s, with the comment updated to "correctness
      fallback under a stream that cannot ack".

## F. Server tests (`server/test/`)

- [ ] F1. Socket framing: split/merged chunks, `id` always present, ping/pong.
- [ ] F2. Coalescing: N events during one in-flight read ⇒ exactly one extra read,
      and the last revision is read. (Fake in-flight read with a deferred
      promise.)
- [ ] F3. Identical read ⇒ no emit.
- [ ] F4. Append ⇒ prefix delta with the exact prefix; repaint ⇒ `reset:true`.
- [ ] F5. Non-selected pane event ⇒ no read.
- [ ] F6. Structure event ⇒ the right `herdr_structure` payload.
- [ ] F7. Drop mid-read ⇒ no partial emit; reconnect re-subscribes.
- [ ] F8. `herdr_watch` validation rejects an injection-shaped pane id.

## G. App tests

- [ ] G1. Push applies a prefix delta, then a reset.
- [ ] G2. Structure push updates the tab/pane rows without a poll request.
- [ ] G3. A push that changes nothing does not notify.
- [ ] G4. Watchdog is 12 s and still works when no push arrives.

## H. Latency measurement (real PC, writable evidence)

- [ ] H1. Create a **temporary shell pane inside wJ only**, e.g.
      `herdr pane split wJ:p5 --direction down --cwd D:\MyNewProjects\cloudterminal`.
      **Never** target `wJ:pB` or `wJ:p5`, and never touch another workspace.
- [ ] H2. Measure desktop-change → phone-display latency with a timestamped
      probe: emit a line on the temp pane (`pane send-text`), timestamp the
      `pane.output_changed` arrival, the push write, and the phone-side apply.
      Report p50/p95 over ≥ 20 samples.
- [ ] H3. Record the numbers in `notes.md`, with the method and the caveats
      (same-machine loopback vs LAN vs public relay).
- [ ] H4. Close the temporary pane and verify `pane list --workspace wJ` is back
      to `wJ:p5` + `wJ:pB`.

## I. Cleanup

- [ ] I1. Delete `server/scripts/herdr-socket-probe.cjs`,
      `herdr-socket-subscribe.cjs`, `herdr-socket-live.cjs` (their findings move
      into `herdr-socket.ts` + the spec/notes).
- [ ] I2. Update `.trellis/spec/backend/herdr-protocol.md` (socket surface,
      watch request, push messages, no-ack consequence) and
      `.trellis/spec/frontend/herdr-ui.md` (push application, 12 s fallback).
- [ ] I3. Parent PRD scope-change note.

## Review gates

- **Gate A (after B)**: coalescing is lossless and timer-free; a burst produces
  at most one extra read.
- **Gate B (after D)**: push reaches both relay entries; `--no-herdr` leaves
  everything as before.
- **Gate C (after G)**: analyze + flutter tests green; a push alone updates the
  rows (no poll).
- **Gate D (after H)**: latency numbers recorded, temp pane removed, wJ intact.

## Explicitly not doing

- No PC Herdr config change; no `allow_nested`; no `attach --takeover`.
- No hand-rendered Herdr UI on the phone; bytes go into the existing terminal.
- No debounce anywhere on the hot path.
