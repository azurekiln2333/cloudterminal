# Herdr mobile UI contract

Backend wire rules live in [herdr-protocol.md](../backend/herdr-protocol.md).
This file covers the Flutter side: models, controller, screens and the
no-fake-data rule.

## Layers

| File | Owns |
| --- | --- |
| `lib/models/herdr.dart` | Typed mirror of the `herdr_*` wire types, lenient parsing, `HerdrActions` payload builders, agent-kind and key constant lists |
| `lib/state/herdr_controller.dart` | Availability, workspace/agent/tab/pane/layout caches, `refresh()`, push application (`applyPaneOutput` / `applyStructure`), per-pane terminals, `watchPane`, the `_inFlight` action guard, error prefix stripping |
| `lib/screens/herdr_screen.dart` | Workspaces → tabs → panes → agents, create/rename/focus/close, confirmation dialogs. Refreshed on open and pull-to-refresh |
| `lib/screens/session_screen.dart` | Existing session body; Herdr mode reuses the same interactive pane widget |
| `lib/screens/herdr_terminal_screen.dart` | Pane route independent of `SessionView` / PTY creation, subscription lifecycle and mobile navigation |
| `lib/widgets/herdr_terminal.dart` | Phone-sized xterm replay, direct keyboard/IME/paste input, serial `HerdrPaneInput` queue and auxiliary terminal keys |
| `lib/widgets/herdr_terminal_rows.dart` | The tab row + pane chip row drawn above the generic terminal; the terminal itself renders Herdr at the phone's geometry |
| `lib/widgets/herdr_status.dart` | Status chips/colours, `herdrStatusHint`, `HerdrPath` |
| `lib/state/remote_controller.dart` | Thin typed passthroughs (`herdrInfo`, `herdrWorkspaces`, `herdrRead`, `herdrPrompt`, `herdrAct`, `herdrWatch`, …) reusing `_request`, plus forwarding of the `herdr_pane_output` / `herdr_structure` pushes to a `HerdrPushSink` |
| `lib/widgets/workspace_sidebar.dart` | The Herdr destination, disabled with inline reason when unavailable |
| `lib/screens/home_screen.dart` | Routes to `HerdrScreen`, preserving the existing drawer/wide-layout pattern |

## Rules

- **Never invent data.** Every list, status and output line comes from the
  desktop agent. When Herdr is unavailable the screen shows the availability
  reason and a disabled entry — not a sample workspace. `HerdrController` clears
  its caches when the bridge is unavailable or the link drops, so stale lists are
  never presented as live.
- **Lenient parsing.** Unknown fields are ignored, an unknown `agentStatus`
  becomes `HerdrAgentStatus.unknown` rather than throwing, and a missing optional
  field is simply absent. A newer desktop agent must never crash the app.
- **One in-flight action per key.** Mutating controls call
  `HerdrController.run(key, action)`; a re-entrant call for the same key resolves
  to `null` without running. The matching button is disabled while busy. This is
  the duplicate-agent / duplicate-submit defence — there is no auto-retry.
- **No blind resend.** `agent_prompt_stalled` and `timeout` surface as a
  long-duration snackbar with no retry. The send button re-enables only after the
  request settles, so the user deliberately chooses to retry.
- **Destructive actions confirm.** Closing a workspace, tab or pane goes through
  a dialog naming the target and its panes/agents.
- **Read sources are explicit.** `HerdrReadSource` maps the labelled UI choice to
  the exact wire value; output is delivered as text and appended/refreshed, never
  truncated into a "sample".
- **Replay a snapshot at the phone's geometry.** The push payload is a flattened
  grid. Rebuild it from `prefix`/`chunk`, then replay the complete screen with
  CRLF-normalised interior line endings and exactly one final line terminator
  removed. A bare LF step-indents lines; a final CRLF can scroll the first row
  away. ANSI must be interpreted by xterm. Preserve meaningful indentation,
  spaces and blank rows; measure cell widths with xterm's `UnicodeV11.wcwidth`.
  For mobile replay, confirmed uniform row-end grid padding may be removed from
  the display copy so it cannot wrap into extra blank rows. Preserve the source
  snapshot, real blank rows, indentation, interior spaces and styled background
  fill; input text never passes through this display transform.
  Infer a grid edge from the **maximum display width**, with at least two rows
  supporting that width. Short or empty rows must not outvote the widest rows.
  With flattened snapshots, intentional plain trailing spaces exactly at that
  edge cannot be distinguished from grid fill; preserve the original snapshot
  and do not apply this inference to input or styled background fill.
  While detecting styled fill, consume extended SGR colour arguments as one
  operation (`38/48/58;5;n` or `38/48/58;2;r;g;b`). Colour values such as `0`,
  `7` and `49` are payload, not reset, reverse or background-reset operations;
  a later independent SGR operation must still take effect.
  The user explicitly chose **phone-width wrapping at a readable font size** on
  2026-10-15. Fill the remaining screen before and after the keyboard opens;
  long rows wrap to phone columns and every replayed row remains scrollable.
  Source-grid dimensions are metadata, not the default mobile viewport. Do not
  shrink the entire PC grid to fit or resize the desktop pane from phone layout.
- **Type directly into the terminal.** A tap focuses xterm and attaches the soft
  keyboard. Committed IME text, hardware keys and auxiliary keys use xterm's
  encoder and raw `herdr_send_text`; no default composer or guessed local echo. Preserve spaces,
  Unicode and control characters in the outgoing request. This does not imply
  every control reaches the desktop process: the verified Herdr 0.9.3 / Windows
  ConPTY path loses NUL after accepting the socket request (see the backend
  contract). Auxiliary keys retain terminal focus.
  `herdr_prompt` remains a separate agent-task action in the non-terminal
  transcript composer. Pane mode uses direct terminal input and has no separate
  agent-task composer.
- **Clipboard intent belongs to the real target.** The app's paste button and
  hardware paste shortcuts share one guarded clipboard read. Queue the original
  text directly with `paste: true`; do not call local `Terminal.paste`, add
  bracketed-paste markers, or normalize clipboard LF into CR. The desktop routes
  this to Herdr `pane.send_input`, which uses the target pane's real paste mode.
  Ordinary IME commits stay raw; text delivered by an IME without clipboard
  provenance must not be guessed to be paste from its length or contents.
  Require `herdr_paste` from the current agent-info negotiation. If unavailable
  or not yet known, show the update/reconnect error and send no clipboard bytes;
  never degrade paste to raw text. Prior connection capabilities cannot authorize
  a replacement Agent before its own info response arrives.
- **Input captures its pane when the event is created.** Serialize writes and
  await each acknowledgment before sending the next. A pane switch must never
  retarget queued bytes. Capture paste intent with the pane, and never merge
  paste with typing or another clipboard action. Chunk large pastes without
  splitting surrogate pairs and keep `paste: true` on every chunk. Each chunk is
  a separate target-side paste operation, not one atomic arbitrary-length paste.
  Cancel a delayed clipboard read when its selection/link becomes stale. A link
  drop clears pending input; it must not replay on reconnect. Invalidate an old
  drain before either its success or failure touches a replacement queue.
- **Herdr input has no PTY prerequisite.** Gate on the live connection and
  `HerdrController.canControl`, not a local session's `_v.gone` / `isClosed` /
  `loaded`. Opening a pane with an empty session list must issue no
  `create_terminal` or unrelated session subscription.
- **Replay produces no outbound input.** Suppress `Terminal.onOutput` while
  applying snapshots: DA/DSR queries in the screen text can cause synchronous
  emulator replies, which must never be injected into the desktop pane. The
  renderer's `onResize` only triggers a local replay after layout. It sends no
  desktop geometry change.
- **Terminal modes need separate evidence.** Current pane snapshots carry text,
  format and revision, without explicit desktop terminal-mode metadata. xterm's
  encoder respects modes parsed locally, but this alone does not prove the
  desktop's application-cursor or other key-encoding modes are synchronized.
  Explicit clipboard paste avoids that gap by delegating paste-mode handling to
  Herdr at the real target; it does not synchronize the phone emulator's modes.
  Do not claim complete TUI mode fidelity from default-key, raw-byte or paste tests.
- **Live state rides a push; the watchdog is a net.** Structure changes arrive
  from the agent's socket subscription within tens of milliseconds and are applied
  by `HerdrController.applyStructure`, which notifies **only when something
  actually changed**. Pane content arrives as `herdr_pane_output`, validated
  against the held text (a bad `prefix` falls back to a full replace) and written
  into an xterm `Terminal` — never composed by hand. Because Herdr's
  `events.subscribe` is silent when a subscription is invalid, the 12 s
  `HerdrController.watch()` / `unwatch()` tick remains as the **correctness
  fallback**; it is no longer how changes are normally noticed. A periodic timer
  in widget code makes `pumpAndSettle` loop forever, which is why a push/tick that
  changes nothing must not notify.
- **Material 3 and Chinese copy.** Reuse `AppTheme` surfaces/radii and the mono
  text style; keep the existing session/Claude/Codex navigation intact. Herdr is
  an additive destination.

## Wire-shape agreement

`HerdrWorkspace.toJson()` and `HerdrAgent.toJson()` list the canonical field
names next to the parser. `test/herdr_test.dart` asserts them, so renaming a
field on only one side of the wire breaks the test instead of shipping silently.
`test/node_integration_test.dart` exercises the same field names against a real
Node agent (`demo-agent.ts --herdr`) over a real WebSocket.

## Cases and tests

- Base: workspaces render with label/number/counts/status/focus; expanding a
  workspace reveals panes and agents.
- Good: availability + workspaces + agents load; reading uses the selected
  source/line count; a close sends nothing until confirmed.
- Bad: unavailable Herdr shows the reason and no create button; a typed error is
  shown with its prefix stripped; a stalled prompt is an error and sends once.
- Device runtime is a separate gate: use the OHOS phone in
  [debug-devices.md](./debug-devices.md). Record the installed artifact and real
  screenshots/input evidence; host tests alone do not prove mobile behaviour.

## Scenario: mobile replay and subscription recovery

### 1. Scope / trigger
Opening, resizing, leaving/reopening, or reconnecting a watched pane must keep
the mobile view readable and restore output without touching desktop geometry.

### 2. Signatures
`watchPane(String? paneId, {bool explicit = false})`, `suspendWatching()`,
`resumeWatching()`, and `applyPaneOutput({paneId, reset, prefix, chunk, format})`.

### 3. Contracts
The current subscription and remembered explicit choice are separate state.
Leaving stops the subscription but remembers the choice. Reconnecting reissues
an active watch even if its id is unchanged; a suspended screen stays suspended.
Only a complete pane list for the id's owning workspace may invalidate a choice.

### 4. Validation and error matrix
| Condition | Required result |
| --- | --- |
| Same pane id after link reconnection | Send a fresh `herdr_watch`; resume output |
| Screen suspended before reconnection | Do not restart its subscription |
| Remembered id absent from its complete workspace listing | Clear it and allow valid fallback selection |
| Cold cache or another workspace's listing | Preserve the remembered id |
| Narrow phone or visible keyboard | Fill available bounds; wrap long rows; preserve scroll access |
| Horizontal insets | Fit columns to `box.width - padding.horizontal`, not the whole box |
| Wide glyph with one cell left on a row | Move the whole glyph to the next row; a single empty end cell is valid |

### 5. Good / base / bad cases
Base: a short snapshot fills the viewport at a readable font. Good: a long CJK
row wraps, first and last content remain reachable, and a reconnect resumes the
same selection. Bad: frozen output after Wi-Fi recovery, PC-sized default canvas,
or a stale closed id that keeps suppressing fallback selection.

### 6. Required tests
Mounted widget assertions must check viewport bounds with and without keyboard,
phone column count, actual wrapped content and scroll access to first/last rows.
After layout, assert `padding.left + columns * cellWidth <= box.width - padding.right`.
Exercise odd and even column counts with CJK and mixed ASCII; concatenate the
rendered runs to prove every character survives, and check width-two glyphs have
their continuation cell on the same row. A source-buffer string assertion alone
does not prove glyphs fit the screen. Repaint after the renderer completes a size
change, including the first layout and height changes with a static snapshot.
Controller tests must assert a fresh watch after reconnection, no background
watch for a suspended screen, and authoritative versus partial-cache recovery.
Direct-input tests exercise the actual text-input connection and hardware keys,
Chinese composition/commit, clipboard selection and paste, auxiliary focus,
captured targets and intent, typed/paste queue separation, per-chunk paste flags,
LF preservation, failed/abandoned drains and replay query suppression. Assert
zero clipboard writes without `herdr_paste`, including the stale-capability
window after reconnecting to a replacement Agent and a delayed/failed info probe.
Keep
`mobile_navigation_test.dart` and `mobile_acceptance_test.dart` independent from
the input widget's implementation; tests that only find a widget do not prove
that tapping it sends the correct bytes or that its glyphs fit the viewport.

### 7. Wrong vs correct
Wrong: `if (currentId == requestedId) return` also suppresses the re-watch on a
new connection, or source columns force the phone to use PC geometry.
Correct: deduplicate within a connection, explicitly restore the active watch on
reconnection, and replay into a viewport sized from the phone's available area.
Wrong: draw the last cell at `padding.left + (columns - 1) * cellWidth` but count
columns from the full box width, or write a double-width glyph into its last cell.
Correct: subtract both horizontal insets and wrap a wide glyph before writing it
when fewer than two cells remain.
