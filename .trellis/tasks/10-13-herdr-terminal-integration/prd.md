# Herdr control inside the generic terminal

## Why

The previous Herdr work read a *screen snapshot* from the desktop pane and
tried to render it on the phone. That is a dead end: the snapshot is painted at
the desktop's column count (often 120+), so on a phone it either truncates
(raw columns) or reflows into a broken TUI layout. The user's verdict: worse
than opening a plain terminal and typing `herdr`.

Meanwhile the project *already* has a correct terminal: a real PTY plus
xterm.dart rendered full-screen at the phone's own geometry. Running `herdr`
inside that terminal is exactly as good as the desktop, because Herdr paints
itself at the phone's column count.

So the fix is not "render a snapshot better". It is: **keep the generic
terminal, and let the phone drive Herdr's focus from the outside.**

## What the user asked for

> 通用终端一套 针对agent来识别 我启动herdr 那么 就自动识别展示herdr工作区 tab pane

- One generic terminal path. No separate Herdr page stack.
- When Herdr is running, the app recognises it and surfaces its state.
- Workspaces live in the **drawer/sidebar**.
- Tabs and panes live in **two rows directly below the title bar**, above the
  terminal.
- Tapping a tab/pane/workspace switches Herdr's focus.

## Requirements

### R1 Recognition
The terminal screen must detect that Herdr is reachable and show the Herdr
rows only then. When Herdr is absent/unreachable, the terminal looks exactly
as it does today (no empty rows, no errors).

### R2 Workspace list in the drawer
The drawer lists Herdr workspaces (label, agent status). Tapping one focuses
that workspace and selects it for the rows below.

### R3 Tab row
Directly below the title bar, one row of tab chips for the selected workspace.
The focused tab is visually marked. Tapping a chip focuses that tab.

### R4 Pane row
Below the tab row, one row of pane chips for the selected tab, labelled by the
pane's terminal title/agent and coloured by agent status. The focused pane is
visually marked. Tapping a chip focuses that pane.

### R5 Non-regression
A plain terminal with no Herdr anywhere must keep the current behaviour: full
screen xterm, soft-keyboard row, resize on rotation, session restore. No extra
vertical space consumed.

### R6 Refresh
Herdr state is request/response (no push). The rows refresh on terminal open,
on reconnect, on returning to the screen, and after every successful focus
action.

## Acceptance criteria

1. Opening a terminal where Herdr runs shows both rows within one refresh
   cycle; opening a terminal elsewhere shows neither.
2. Tapping a pane chip on the phone moves the desktop Herdr focus to that pane
   (verifiable with `herdr pane current`), and the phone terminal repaints to
   that pane.
3. Tapping a tab chip focuses that tab; the pane row then lists that tab's
   panes, and the focused pane chip follows.
4. Selecting a workspace in the drawer focuses it and repopulates both rows.
5. With no Herdr available, the terminal area is byte-for-byte the same layout
   as before this change (no reserved height).
6. `flutter analyze` clean and the full `flutter test` suite green.

## Out of scope

- Reading pane output as text for display (the rejected snapshot approach).
- Any new terminal session kind, protocol message, or server capability:
  `workspace_focus`, `tab_focus`, `pane_focus`, `herdr_workspaces`,
  `herdr_tabs`, `herdr_panes` already exist.
- Creating, renaming, splitting, or closing panes from these rows.
- Splitting the terminal screen into a page per pane.
