# Herdr wire contract

## Scope and ownership

CloudTerminal does not embed Herdr. It talks to the **locally installed `herdr`
CLI** and forwards a typed subset over the existing authenticated relay.

- `server/src/agent/herdr.ts` owns discovery, validation, argv construction and
  JSON mapping. It is the only module that spawns Herdr's CLI.
- `server/src/agent/herdr-socket.ts` owns socket transport: endpoint resolution,
  incremental UTF-8/newline-JSON framing, the ack-gated `events.subscribe`,
  reconnect/re-subscribe, and short `pane.read` / `pane.send_text` /
  `pane.send_input` connections.
- `server/src/agent/herdr-live.ts` turns socket events into pushes: structure
  listings, and the selected pane's content read with per-pane coalescing and
  prefix deltas.
- `server/src/shared/protocol.ts` owns the wire types; `lib/models/herdr.dart`
  mirrors them. `server/src/agent/core.ts` routes `herdr_*` requests; `AgentCore`
  takes an optional `herdr?: HerdrBridge` and `herdrLive?: HerdrLivePush`, exactly
  like `codex?`.
- The relay stays opaque. It never parses Herdr payloads.
- Flutter side: `lib/state/herdr_controller.dart` (cache + in-flight guard +
  push application + watchdog fallback),
  `lib/screens/herdr_screen.dart` (workspaces → tabs → panes → agents),
  `lib/widgets/herdr_terminal_rows.dart` (tab/pane rows above the terminal),
  `lib/screens/session_screen.dart` and `lib/screens/herdr_terminal_screen.dart`
  (both reuse the interactive `lib/widgets/herdr_terminal.dart` pane renderer).

Structural actions and agent prompts use the CLI. Interactive terminal input
uses socket `pane.send_text` for raw keys and `pane.send_input` for explicit
clipboard paste, avoiding a CLI process for each input. Socket transport remains confined to `herdr-socket.ts`;
`HerdrBridge` validates input and maps errors, and `herdr-live.ts` owns pushes.
Framing, source, subscription and input assumptions are covered by the Herdr
test suites, including `herdr-socket-call.test.ts` with real isolated sockets.

## Binary resolution and availability

Resolution order (first hit wins): `CLOUDTERMINAL_HERDR_PATH` → persisted
`herdrPath` → `herdr` on `PATH` → known install dirs
(`%ProgramFiles%\herdr-windows-*`, `~/.local/bin`, `/usr/local/bin`,
`/opt/homebrew/bin`). Probed once per process and cached.

Availability is cached ~10 s and refreshed on `herdr_info {force:true}`:

- `herdr --version` must match `^herdr\s+(\S+)$` (anchored; `not herdr` must not
  parse as installed).
- `herdr status` supplies `server.status`, `client.protocol`, `server.socket`.

Concurrent discovery shares one pending probe. `socketPath()` and terminal input
use the same cached availability; they must not run `--version` / `status` for
every key. A failed input is never resent after discovery refresh.

`herdr` capability is advertised in `info.capabilities` only when
`availability.available`. It is add-only: `--no-herdr`, a missing binary or a
stopped server leaves every other feature unchanged and returns
`herdr_unavailable:<reason>`, where `<reason>` is the actionable Chinese message
(`没安装` / `服务未运行` / `版本无法确认`).

## Requests and replies

Client requests (all additive, `PROTOCOL_VERSION` unchanged):
`herdr_info`, `herdr_workspaces`, `herdr_tabs`, `herdr_panes`, `herdr_agents`,
`herdr_agent`, `herdr_layout`, `herdr_read`, `herdr_prompt`, `herdr_send_text`,
`herdr_send_keys`, `herdr_run`, `herdr_wait`, `herdr_act {action}`.

Agent messages: `herdr_info`, `herdr_workspaces`, `herdr_tabs`, `herdr_panes`,
`herdr_agents`, `herdr_agent`, `herdr_layout`, `herdr_output`,
`herdr_result {action, summary, data?}`. Every reply echoes the request `id`.

These are request/response **plus a push stream**. Pane content is read on
demand with an explicit source; Herdr offers no change feed over the CLI, but the
server socket does (see below).

Reconnect recovery re-lists Herdr state and reissues an active `herdr_watch`.
`AgentCore.clientLeft` drops the disconnected client's watch, so re-listing alone
cannot restore output even when the selected pane id has not changed. A screen
that suspended its watch must remain unsubscribed.

### Live push

`events.subscribe` (`{subscriptions: [{type}]}`) replies
`{"type":"subscription_started"}` and then emits `{event, data}` frames. Two
properties matter:

- **Subscription type names are dotted** (`tab.created`); the delivered event
  name is **underscored** (`tab_created`). Event frames carry no `id`; replies
  do.
- **An invalid entry, or one missing a required param, poisons the whole
  subscription**: the server accepts the frame and then never acks and never
  emits. `pane.output_changed` is not in the union at all, and
  `pane.agent_status_changed` / `pane.scroll_changed` / `pane.output_matched`
  require `pane_id` (some also `source`/`match`) *inside the entry*. All four
  behave that way, so the client treats a missing ack as a failure, and the
  subscription list is asserted by test against the server's union.

There is also **no content-change edge**: `pane.updated` never fires for output,
`pane.output_matched` fires only on a match, and `pane.scroll_changed` was not
observed. Content is therefore read from the socket on a short tick
(`pane.read`) for the one selected pane. A `pane.read` reply is followed by
the server closing that connection, so reads use a fresh short-lived connection.

#### The content read must be side-effect free

`pane.read` **must** send `source: 'visible'`, `format: 'ansi'`,
`strip_ansi: false` (`paneReadParams` in `herdr-live.ts`, asserted by test):

- `recent` / `recent_unwrapped` make Herdr **capture scrollback**, which it can
  only do by scrolling the pane while the hosted agent is idle. Reading that on a
  tick drives the desktop pane into continuous scrolling and can move the desktop
  user's scroll position. Herdr refuses the history sources outright when the
  agent is not idle (`agent_not_idle`).
- The default `format` is `text` with `strip_ansi: true`, which discards every
  positioning sequence. What arrives is a **flattened grid**, so it must be
  treated as a snapshot rather than a PTY byte stream: line endings normalised to
  CRLF (a bare LF does not return the carriage, so lines step-indent), and exactly
  one final terminator removed to prevent replay scrolling the first row away.
  Meaningful spaces/blank rows survive. Source widths are measured with xterm's
  `UnicodeV11.wcwidth`; mobile replay wraps at the phone's columns as specified in
  [Herdr UI](../frontend/herdr-ui.md), without resizing the desktop pane.

#### Selection identity

A read publishes only if the selection it started against is still current,
checked by a monotonic **generation plus state identity** — not by comparing pane
ids. A → B → A returns to the same id, so an id comparison would let the first
read land on the second selection.

#### Pane input

Input to a watched pane uses **terminal semantics**, kept separate from agent
prompts. The request is `herdr_send_text { paneId, text, paste?: boolean }`.
An omitted or false `paste` means xterm-encoded keyboard/IME/auxiliary bytes;
true means original clipboard text. Reject any supplied non-boolean before
discovery or delivery. The validator and JSON/socket request preserve CR,
DEL, ESC sequences, NUL and Unicode, with a 64K UTF-16 length limit and no trimming
or control stripping. Prompt validation remains separate and NUL-stripped.

Validator/request fidelity is not proof of downstream delivery. On the verified
Herdr 0.9.3 / Windows ConPTY path, `pane.send_text` acknowledges NUL-containing
input but the receiver loses the NUL: `nul\u0000inside` arrives as `nulinside`.
The same loss occurs when calling the Herdr socket directly, outside this bridge;
the exact internal component responsible has not been established.
Do not claim end-to-end NUL support or change validation tests to conceal this
platform limitation. Real receiver checks verified English, CJK, spaces, Tab,
CR, DEL, arrow ESC sequences and Ctrl-C. Retain failed NUL acceptance evidence
separately from successful ordinary-key checks.

The bridge calls `pane.send_text {pane_id, text}` for raw input and
`pane.send_input {pane_id, text}` only for explicit `paste: true`. Raw control
keys must never use `pane.send_input`: its paste-mode wrapping changes their
semantics. Clipboard text must not be bracket-wrapped by the phone emulator;
Herdr applies the real target pane's current paste mode. Both paths require
`result.type === 'ok'`, and neither retries or falls back to the other method.

`AgentCore` advertises `herdr_paste` alongside `herdr` in `info.capabilities`
when Herdr is available. The phone must require that capability from the current
connection's agent-info negotiation before sending `paste: true`. An older
Agent may silently ignore unknown fields, so missing/unknown capability must
produce a visible update/reconnect error rather than raw-input fallback.
Invalidate prior paste negotiation when the agent/link changes; stale capability
state must not authorize clipboard input to a replacement Agent. Raw requests
remain compatible with older Agents; `PROTOCOL_VERSION` stays unchanged.

Queue entries capture both pane and paste intent. Never merge typed input with
paste, or distinct clipboard actions with one another. Every chunk of a long
paste carries `paste: true`, preserves its text and surrogate boundaries, and
waits for its own acknowledgement. Chunks are separate target-side paste
operations; the protocol does not promise one atomic paste for an arbitrary
length clipboard.

Herdr 0.9.3 / wire 22 reads one initial request per ordinary connection; its event connection does
not read subsequent requests. Every input therefore uses a short connection,
never the subscription. Match the request ID, preserve remote error codes and
reject EOF before a reply. A timeout or lost acknowledgment may follow a
successful write, so there is no CLI fallback, retry or automatic resend.

Logical-key actions remain available through `herdr_send_keys`.
`herdr_prompt` is an explicit, separate action for submitting a task to a hosted
agent and is never used for keystrokes.
Pane ids use base-36 suffixes (`wJ:pB`, `wJ:pS`, `wJ:tA`), not digits.
For a pane-id target, logical keys must invoke `pane send-keys`, including panes
hosting only a shell. A live agent-name target continues to use `agent send-keys`.
Routing pane-id keys through the agent verb rejects shell panes after text lands.
Tests must assert both argv paths and text-before-Enter ordering.

Both CLI `send-keys` verbs may succeed with **exit 0 and empty stdout**. The
bridge's JSON helper accepts that through an explicit `allowEmpty` opt-in.
Non-zero exit and empty list/read/agent/layout output still fail. Raw terminal
text requires the socket acknowledgment described above.

Messages (additive; `PROTOCOL_VERSION` unchanged):

- request `herdr_watch { paneId }` — selects the streamed pane (validated with
the pane-id rule); `paneId: null` clears it. Structure pushes continue either way.
- push `herdr_pane_output { paneId, revision, format, reset, prefix, chunk }` —
`format` is `ansi`; `reset` means "replace with `chunk`", otherwise append `chunk`
to the first `prefix` characters already held. The receiver validates `prefix`
and falls back to a full replace on mismatch.
- push `herdr_structure { workspaceId?, workspaces?, agents?, tabs?, panes? }` —
only the parts that changed; the phone patches its caches and issues no read.

`HerdrAction` is a discriminated union covering create/rename/focus/close for
workspace, tab and pane; split/zoom/resize/move pane; start/rename/focus agent.
Interactive attach/takeover and `--machine`/`--remote` forwarding are out of
scope and are never faked.

## Validation — the security boundary

Every mobile-supplied value is validated on the desktop before any invocation.
Invalid values raise `HerdrArgumentError` → wire prefix `herdr_invalid_argument:`.

| Slot | Rule |
| --- | --- |
| workspace id | `^w[0-9A-Za-z]{1,8}$` |
| tab id | `^w[0-9A-Za-z]{1,8}:t[0-9A-Za-z]{1,4}$` |
| pane id | `^w[0-9A-Za-z]{1,8}:p[0-9A-Za-z]{1,4}$` |
| agent target | pane id **or** `^[a-z][a-z0-9_-]{0,31}$`; a bare kind label is refused |
| agent name | `^[a-z][a-z0-9_-]{0,31}$` (Herdr's own rule) |
| agent kind | one of Herdr's 24 kinds |
| direction | `left\|right\|up\|down` |
| read source | `visible\|recent\|recent-unwrapped\|detection` |
| lines | integer 1..5000 |
| ratio | 0.05..0.95 |
| label | ≤120 chars, no control chars |
| prompt text | free text, NUL-stripped, ≤64 KiB |
| raw terminal input | string, validator/request preserve all controls, ≤64K UTF-16 units; downstream NUL limitation above |
| clipboard intent | optional boolean `paste`, default false; reject other types before I/O |
| logical key | fixed allowlist (no destructive keys) |
| repeat | integer 1..50 |

**No shell, ever.** Invocations are argv arrays with `shell:false`; a prompt
containing `\n`, `;`, backticks or `&&` stays inside one argv element and is
never interpolated into a command line. `pane run` is a separate explicit
operation whose string is a single argv element — Herdr owns the shell.

## Errors

Herdr failures become the existing `{kind:'error', message}` channel with a
stable prefix so the app can branch without parsing prose:
`herdr_unavailable:`, `herdr_invalid_argument:`, `herdr_failed:<code>:`, with the
raw code retained for diagnostics. `pane_not_found`, `agent_not_found`,
`agent_not_ready`, `agent_blocked`, `agent_prompt_stalled` and `timeout` each map
to a distinct Chinese sentence naming the next action.

`agent_prompt_stalled` and `timeout` mean **do not blindly retry**: the bridge
never retries a prompt internally, and the app disables the send control while a
request is in flight (`HerdrController._inFlight`), which is also the
duplicate-agent-start defence.

`pane read` prints raw screen text on success, but a failure still returns a JSON
`{"error":...}` envelope. `read()` detects that envelope and raises a typed error
instead of leaking it as output. Ordinary JSON-looking screen text is preserved.

## Cases and tests

- Base: availability (installed / server stopped / missing) yields the three
  reasons; listings parse real recorded shapes; read returns raw text.
- Good: every action builds the exact argv shape (asserted separately, not as one
  string); a `\n` in prompt text stays in one element; unknown Herdr status
  degrades to `unknown` instead of throwing.
- Bad: injection-shaped ids/labels/keys/kinds/directions/line counts are rejected
  before spawning; a bad pane id is `pane_not_found`; a stalled prompt is an error
  raised once (the fake runner is called exactly once).
- Input: omitted/false paste selects `pane.send_text`, true selects
  `pane.send_input`, with the same unmodified request body and no failure retry.
  Assert strict boolean validation before I/O and capability advertisement only
  when Herdr is available. Real receiver checks must distinguish a socket `ok`
  from actual byte delivery and verify clipboard behavior with the target pane's
  bracketed-paste mode enabled and disabled.
- Required: `server/test/herdr.test.ts` (injected runner, real fixtures),
  `AgentCore` routing with and without a bridge, `test/herdr_test.dart`
  (models/controller/widgets/field-name contract), and the Dart↔Node
  cross-layer test in `test/node_integration_test.dart` driven by
  `demo-agent.ts --herdr`.

## Real-server smoke (opt-in, isolated)

`server/scripts/herdr-smoke.ts` refuses to run without
`CLOUDTERMINAL_HERDR_SMOKE=1`, sweeps leftover `ct-probe-*` workspaces, creates
and closes one probe workspace, and asserts the workspace id set is unchanged. It
never focuses, renames or closes a pre-existing workspace and never starts an
agent. Recorded evidence lives under `.build/pi-herdr/`.
