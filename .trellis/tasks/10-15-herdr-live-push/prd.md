# Herdr live push (socket events + pane delta streaming)

Parent: `10-13-herdr-mobile-render`.
Supersedes the "no push stream" assumption with an explicit, user-approved scope
change (recorded in the parent PRD).

## Why

The user's requirement is **the lowest latency achievable** for seeing a desktop
Herdr pane on the phone, and for tab/pane structure changes to reach the phone
without the user touching anything.

The previous design assumed Herdr offers no change feed. That is **wrong at the
socket level**: the CLI has no event command, but the Herdr **server socket API**
does. Probed on herdr 0.9.3, protocol 22:

- Windows endpoint: named pipe `\\.\pipe\<socket path from `herdr status`>`.
- Framing: newline-delimited JSON, `{"id","method","params"}` →
  `{"id","result":…}`.
- `ping` answered with `pong` (proves the framing).
- `events.subscribe` accepts a subscription list and **does not ack**; it only
  emits when a matching event happens.
- Subscribable events include `pane.output_changed` (carries `pane_id`,
  `workspace_id`, `revision`), plus structure events: `workspace.updated`,
  `tab.created`, `tab.closed`, `tab.focused`, `pane.created`, `pane.closed`,
  `pane.updated`, `pane.focused`, `pane.moved`, `pane.exited`,
  `pane.agent_status_changed`, `layout.updated`.

`pane.output_changed` carries only a **revision**, not the bytes. Content still
comes from `pane read`. So the low-latency design is: **edge-triggered, not
polled** — subscribe once, and on each event read the pane and push.

### Measured in situ (2026-10-15, herdr 0.9.3 / protocol 22 / Windows)

All numbers from probes on a throwaway tab created inside `wJ` and deleted
again; the user's own panes were never sent input.

| Capability | Result |
| --- | --- |
| `events.subscribe` with **only valid** types | Repies `{"type":"subscription_started"}` in ~100 ms, then streams |
| Any **invalid** subscription type | Silently accepted, **no ack and no events ever** — one bad entry poisons the whole subscription. This is the trap the first probe fell into (`pane.output_changed` is *not* a subscription type) |
| `tab_created` / `pane_created` edge | **~41 ms** after the change, payload is the full tab/pane object |
| `pane.output_matched` | Edge on **matching** output, **~59 ms**, carries `read.text` + `revision`. Fires once immediately on subscribe (it matches existing content), and then only when new output matches. Requires `pane_id`, `source`, `match` |
| `pane.updated` | **Never fires for content changes** (structure only) |
| `pane.scroll_changed` | Not observed |
| `pane.read` / `workspace.list` / `tab.list` / `pane.list` / `agent.list` over the socket | Work; a `pane.read` reply is followed by the server closing that connection, so a long-lived connection must not share it with `pane.read` |

Consequences that shape the design:

- Structure events (`tab.*`, `pane.created/closed/focused/moved`, `workspace.*`)
  are a **true edge-trigger** and carry the object, so Bug 2 needs no re-read at
  all — the event payload patches the caches directly.
- There is **no content-change edge**. `pane.output_matched` fires only on a
  match, so it cannot be the general trigger. Pane content therefore uses a
  short, agent-side, *socket* read of the one selected pane (100–200 ms), which
  avoids spawning the CLI per tick.

**Valid subscription types** (the `Subscription` union, 27 entries):
`workspace.{created,updated,metadata_updated,renamed,moved,reordered,closed,focused}`,
`worktree.{created,opened,removed}`, `tab.{created,closed,focused,renamed,moved}`,
`pane.{created,closed,updated,focused,moved,exited,agent_detected}`,
`pane.output_matched`, `pane.agent_status_changed`, `pane.scroll_changed`,
`layout.updated`. Note the dot form here versus the underscore form of the
`event` name that comes back (`tab.created` subscribes, `tab_created` arrives).

### Constraints from the user

- Do **not** change the PC's Herdr config (rules out `allow_nested`, which would
  otherwise let the phone run a herdr client).
- Do **not** hide the PC's workspace/agent bar (rules out `attach --takeover`).
- Do **not** re-render Herdr UI on the phone: the phone writes bytes into its
  existing xterm `Terminal`; nothing is composed or repainted by hand.
- Real-time, no artificial delay: **no debounce**, coalesce instead.
- Bug 2's structure refresh moves onto this same push channel; the app's 3 s
  watchdog is demoted to a correctness fallback at 10–15 s.

## Requirements

### R1 Subscription
The agent opens one persistent connection to the Herdr server socket, sends
`ping` (framing check) and a single `events.subscribe` covering pane output and
the structure events. It reconnects with backoff if the socket drops, and
re-subscribes. When Herdr is unavailable (no binary / server stopped / socket
unusable) behaviour is unchanged: no subscription, existing `herdr_*` reads
still work, no error is shown for the absence of a push stream.

### R2 Edge-triggered pane read (no polling, no debounce)
On `pane.output_changed` for the **selected** pane:
- Read it **immediately** via the existing `pane read` path.
- Push the result to subscribed clients as it is produced — no `setTimeout`
  delay, no timer-based debounce.
- **Coalesce per pane**: while a read is in flight, further events only set a
  "dirty" flag and record the newest revision. When the read completes, if dirty,
  read again immediately. This bounds concurrent reads to one per pane and can
  never drop the final state.
- An event for a non-selected pane updates the structure/agent state only; it
  must not trigger a pane read.

### R3 Delta push, not full frames
A push must send only what changed:
- If the newly read pane text is byte-identical to the last one pushed for that
  pane, send nothing.
- Otherwise send a message carrying a **prefix length**: the receiver keeps the
  last text it was sent and appends the suffix beyond the common prefix. For
  appending terminal output (the common case) this is a small suffix.
- If the new text is not an extension of the old (screen repaint, scroll, pane
  switch), fall back to sending the whole text with `reset: true` so the phone
  rebuilds its buffer rather than displaying a splice artifact.

### R4 Structure changes ride the same channel
`tab.created` / `tab.closed` / `tab.focused` / `pane.created` / `pane.closed` /
`pane.focused` / `pane.moved` / `workspace.*` push the affected listing so the
phone's tab/pane rows update without a poll. The phone applies it to the same
`HerdrController` caches the rows already render.

### R5 Fallback is a correctness guarantee
Because `events.subscribe` does not ack, a silent subscription failure is
indistinguishable from "no events". The app therefore keeps the watchdog, relaxed
to 10–15 s, as the correctness net. The fallback must never be what makes the
common case work — the push must arrive first.

### R6 No fabricated state
The push stream carries only what Herdr reported. A dropped socket clears
in-flight reads and marks the stream stale; it never leaves a partial pane
looking live.

## Out of scope

- Changing the PC's Herdr config, attaching a herdr client on the phone.
- Byte-exact raw PTY streaming (Herdr does not expose it; content is the painted
  screen from `pane read`).
- Rendering decisions beyond writing received bytes into the existing terminal.

## Acceptance criteria

1. A change on the PC (typing in the selected pane) reaches the phone display
   with end-to-end latency measured and recorded in `notes.md`, and the figure is
   materially below the 3 s watchdog the app used to rely on.
2. Creating a tab on the PC makes the phone's tab row show it **without** any
   phone-side poll firing (assert the push path alone updates the rows).
3. Repeated `pane.output_changed` during one in-flight read do not produce
   overlapping reads for the same pane, and the last revision is always read.
4. An unchanged pane produces no push (byte-identical read ⇒ silent).
5. An append-only change produces a prefix-delta message, not the full text.
6. A non-append change produces a full-text reset message.
7. An event for a non-selected pane does not trigger a pane read.
8. Herdr unavailable / socket unusable ⇒ no subscription and no user-visible
   error; the previous behaviour is intact.
9. `server` tests, `flutter analyze`, `flutter test` all pass.

## Confirmed decisions

- Socket API (newline JSON over the named pipe / unix socket) is the transport;
  the CLI stays the control surface.
- Coalesce, never debounce.
- Prefix-delta with a documented reset rule.
- Watchdog becomes a 10–15 s correctness fallback.
- Latency is measured on a **temporary shell pane created inside the cloudterminal
  workspace (wJ)**. Never send input to `wJ:pB` or `wJ:p5`, and never touch panes
  in other workspaces (they host other projects' agents).
