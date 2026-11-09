# Notes — Herdr pane switcher

Working record for the incremental changes made under this task. The renderer
part of the original plan (`HerdrPaneScreen` + `HerdrPaneViewport`) was dropped
and replaced by "the generic terminal renders Herdr at the phone's geometry,
with tab/pane rows above it" — see `10-13-herdr-terminal-integration`.

## 2026-10-14 — Watchdog: tab/pane rows did not follow the desktop

### Symptom

The user reported: three tabs open on the PC, the phone's tab bar still showed
one. Verified against the real PC that the wire data was correct —
`herdr workspace list` and `herdr tab list --workspace wJ` agreed with each
other, so this was not a producer bug.

### Root cause

`HerdrController` reads Herdr over request/response only (Herdr's CLI has no
change feed; confirmed against `herdr api schema`, protocol 22 — the only live
signal is a `pane_output_changed` event carrying a revision number, and that
event is not reachable through the CLI). The caches were filled by `refresh()`
and `loadWorkspace()`, and `HerdrTerminalRows` rendered `visibleTabs` /
`visiblePanes` straight out of those caches.

Nothing re-read them after the screen opened. `SessionScreen.initState` did one
refresh; the only other triggers were connect, pull-to-refresh, and a completed
mutation. A tab created **on the desktop** therefore never appeared.

### Fix (`lib/state/herdr_controller.dart`)

- `watch()` / `unwatch()` / `unwatchAll()` own a reference-counted
  `Timer.periodic` (default 3 s, injectable for tests). Reference counting
  because two screens can be mounted at once — a pane screen pushed over the
  list.
- Ownership is the widget tree, not the link: a timer created by a controller
  can outlive the screen and keeps polling. `SessionScreen` and `HomeScreen`
  arm it; `HomeScreen` releases everything (`unwatchAll()`) when the app leaves
  the foreground and re-arms on resume. `HerdrScreen` deliberately does **not**
  arm it — it is a management page, refreshed on open and pull-to-refresh.
- Ticks are **quiet**: `_refreshQuietly()` skips the loading/probing notify and
  only notifies when a listing signature actually changed. Without this a tick
  repaints the rows every 3 s for no reason — and, concretely, `pumpAndSettle`
  never settles, which broke the existing widget tests.
- A tick is skipped while `_inflightRefresh != null` or `_inFlight.isNotEmpty`,
  so it can never race a create/close the user just triggered.
- `force` (pull-to-refresh, post-mutation) stays a full, notifying refresh.

Two signatures (`_listingSignature` for workspaces/agents, `_detailSignature`
for one workspace's tabs/panes) cover exactly what the rows and the sidebar
render, so a changed `tabCount` or a new tab is never swallowed.

### Tests

- `HerdrController the watchdog re-reads the listing so a desktop-side tab appears`
  — real timers, 10 ms interval: one tab initially, three after re-scripting the
  fake, the tick picks them up.
- `HerdrController the watchdog is armed by a screen and stopped when it leaves`
  — refcount behaviour (two screens, one unwatch keeps polling).
- `HerdrController a tick does not fire while a mutating action is in flight`.
- `Herdr terminal rows a tab added on the desktop appears without user action`
  — widget-level end-to-end: chip labels grow from `main` to
  `main`/`logs`/`tests` after `tester.pump(Duration(seconds: 4))`.
- The controller-level fake gained a `tabs:` parameter so `herdr_tabs` can be
  scripted per test.

### Verification

```
$ flutter analyze
No issues found! (ran in 3.5s)

$ flutter test
00:03 +123: All tests passed!
```

### Specs updated

- `.trellis/spec/frontend/herdr-ui.md` — watchdog rule; the stale
  `herdr_pane_screen.dart` row replaced with `herdr_terminal_rows.dart`.
- `.trellis/spec/backend/herdr-protocol.md` — documented that the app polls
  because Herdr has no change feed, and why the tick is quiet; same stale-file
  fix on the Flutter-side file list.

### Not done

- Bug #1 (single-pane display / live pane content) is untouched: it needs a
  decision on the transport. Field findings are recorded in the session; the
  short version is that `herdr` refuses to run nested without a PC config
  change, `herdr agent attach` is unsupported on Windows, and `pane read` only
  returns painted snapshots.
