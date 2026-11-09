# Design — Herdr control inside the generic terminal

## Boundary shift

The rejected approach put Herdr on its own screen stack (workspace list → pane
list → snapshot viewport). This task deletes that stack and puts Herdr back
where it belongs: as an **overlay on the generic terminal** that already exists.

```
SessionScreen (terminal kind)
├── AppBar                       (unchanged)
├── _HerdrTabRow      ← NEW, only when herdr is reachable
├── _HerdrPaneRow     ← NEW, only when herdr is reachable
├── TerminalPane                 (unchanged: real PTY + xterm, full screen)
└── soft-keyboard row            (unchanged)
```

Workspaces move into `WorkspaceSidebar` (drawer), which already receives the
`HerdrController`.

## Why no snapshot rendering any more

`herdr pane read` returns the desktop's painted screen. Rendering that on a
phone cannot be correct: the frame is authored for ~120 columns, so the phone
must either truncate (raw columns) or reflow (destroyed TUI geometry). The
terminal is the *only* component that renders Herdr at the phone's own
geometry, because Herdr itself asks the PTY for `cols/rows`. So the terminal
stays the display, and the phone only steers focus through the Herdr API.

## Data flow

```
                       ┌──────────────────────────┐
   phone taps a chip ──▶│ HerdrController.workspace│
                       │  / tab / pane action     │
                       └───────────┬──────────────┘
                                   │ herdr_action{kind: pane_focus, paneId}
                                   ▼
                       ┌──────────────────────────┐
                       │  agent HerdrBridge       │  (already implemented)
                       └───────────┬──────────────┘
                                   │ herdr pane focus wJ:p2
                                   ▼
                       ┌──────────────────────────┐
                       │  desktop Herdr process   │  focus moves
                       └───────────┬──────────────┘
                                   │ repaint of the attached client
                                   ▼
                       phone TerminalView (PTY stream) repaints
```

Key property: the focus action and the visible repaint travel over **different
channels** (API socket vs PTY stream), which is exactly how a desktop terminal
client behaves. No new protocol message is needed.

## State ownership

`HerdrController` already owns everything required:

| Need | Existing member |
| --- | --- |
| Is Herdr reachable? | `canControl` (`_availability.available`) |
| Workspace list | `workspaces` + `refresh()` |
| Tabs of a workspace | `tabs(workspaceId)` + `loadWorkspace(id)` |
| Panes of a workspace | `panes(workspaceId)` (filtered by `tabId`) |
| Focus workspace | `run('workspace:<id>', () => remote.herdrAct(...))` |
| Focus tab / pane | same pattern with `tab_focus` / `pane_focus` |

New derived state needed on the controller:

- `String? selectedWorkspaceId` — which workspace the rows describe. Defaults to
  the workspace that the focused pane belongs to (i.e. where the desktop user
  is), so the phone opens already pointing at the right place.
- `String? focusedTabId` / `String? focusedPaneId` — read from
  `HerdrTab.focused` / `HerdrPane.focused`, not stored separately; the rows
  highlight whatever the desktop reports as focused.

Rationale: focus truth lives on the desktop. Storing a phone-side "selected"
flag would drift the moment the user touches the desktop keyboard.

## SessionScreen needs the controller

`SessionScreen` currently receives only `RemoteController` + `SessionView`, so
it cannot read Herdr state. Pass the existing `HerdrController` instance down
from `HomeScreen` (which already owns it as `_herdr`) as an optional
constructor argument.

Optional, not required: `SessionScreen` is also constructed in tests and for
non-terminal sessions, and Herdr rows must stay absent when it is null. This
keeps R5 (non-regression) structural rather than behavioural.

## Recognition (R1)

"Recognise that Herdr is running" = `herdr.canControl`. The controller probes
via `herdr_info`, which asks the agent to resolve the Herdr binary and report
availability. It never inspects the terminal's process tree: that would need
pid-level PTY introspection that node-pty does not expose portably, and it
would still not tell us whether the *user's* Herdr session is the one we can
drive. The API socket is the authoritative answer.

Consequence, and it is the desired one: a terminal on a machine without Herdr,
or with the agent not yet paired, renders **zero** extra widgets.

## Layout budget

Both rows are single-line horizontal scrollers, ~34 px each, rendered **only**
when `canControl && workspaces.isNotEmpty`. The terminal keeps `Expanded`, so
when the rows are absent the layout is pixel-identical to today.

Row visibility rules:

- Tab row: hidden when the selected workspace has ≤ 1 tab.
- Pane row: hidden when the selected tab has ≤ 1 pane.

This keeps the common single-pane case (wJ, wG, wH, ...) completely clean.

## Refresh policy (R6)

`HerdrController.refresh()` is already triggered on remote connect. Add:

- `SessionScreen.initState` → `herdr.refresh()` when Herdr is present and not
  yet loaded.
- After every successful focus action, the existing `run(..., refreshAfter:
  true)` path re-reads and re-notifies, so the highlight follows the desktop.

## Failure behaviour

- Herdr unavailable → rows absent, no error strip.
- Focus action fails (pane closed on desktop) → `HerdrController.error` is set;
  the rows show a dismissible inline strip rather than a modal, and a refresh
  drops the stale chip.
- Link down → rows keep the last known list but disable taps, matching the
  existing `canBrowse` / `canControl` split.

## Deletions

Per the user's instruction, the snapshot stack goes away:

- `lib/screens/herdr_pane_screen.dart` (tab bar + chips + viewport + input)
- `lib/widgets/herdr_pane_viewport.dart`
- `lib/screens/herdr_screen.dart` pane-detail navigation and its list rows

`HerdrController`, `lib/models/herdr.dart`, the server bridge, and the protocol
are **kept** — the new UI is built on them.

> Deletion is staged last, after the new rows work, so the diff stays
> reviewable and a revert is a single `git checkout`.

## Tradeoffs

| Choice | Cost | Why accepted |
| --- | --- | --- |
| Live rows instead of a snapshot viewport | No phone-side text selection of pane history | The terminal already provides scrollback; the snapshot never rendered correctly |
| Focus truth stays on the desktop | A phone-side selection can be overridden by desktop input | Matches how every terminal multiplexer behaves |
| Rows auto-hide at ≤1 tab/pane | A single-pane workspace shows no Herdr chrome at all | Vertical space on a phone is the scarcest resource |
| Pass `HerdrController` into `SessionScreen` | One more constructor dependency | It is the object that already owns the state; inventing a second one would duplicate probes |
