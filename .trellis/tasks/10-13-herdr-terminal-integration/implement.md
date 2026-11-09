# Implement — Herdr control inside the generic terminal

Verification commands (run from repo root):

```powershell
flutter analyze
flutter test
```

Device push (only after both are green):

```powershell
flutter build hap --release
& "D:\ProgramFiles\Huawei\OpenHarmony\Sdk\23\toolchains\hdc.exe" install -r build\ohos\hap\entry-default-signed.hap
& "D:\ProgramFiles\Huawei\OpenHarmony\Sdk\23\toolchains\hdc.exe" shell aa start -a EntryAbility -b com.azurekiln.cloudterminal
```

Rollback point: `git checkout -- lib/ test/` (all edits are confined to app
code; nothing in `server/` changes).

---

## A. Controller: derive the selection from desktop focus

- [ ] A1. In `lib/state/herdr_controller.dart`, add
      `String? get selectedWorkspaceId` — resolves in order:
      1. an explicit `_selectedWorkspaceId` set by the drawer,
      2. the `workspaceId` of the pane whose `focused == true` in `_panes`,
      3. the `focused == true` workspace in `_workspaces`,
      4. the first workspace.
- [ ] A2. Add `void selectWorkspace(String id)` that sets `_selectedWorkspaceId`,
      calls `_notify()`, and fire-and-forgets `loadWorkspace(id)`.
- [ ] A3. Add `List<HerdrTab> get visibleTabs` = `tabs(selectedWorkspaceId)`.
- [ ] A4. Confirm `HerdrTab.focused` / `HerdrPane.focused` are parsed from the
      wire (they are: `herdr_tabs` / `herdr_panes` map `focused`). If a field is
      missing, add it to `lib/models/herdr.dart` — do **not** invent phone-side
      focus state.
- [ ] A5. Add focus helpers so the UI never builds raw action JSON:
      `Future<void> focusWorkspace(id)`, `focusTab(tabId)`,
      `focusPane(paneId)` — each wraps `run('…:<id>', () => remote.herdrAct(
      {'type':'herdr_action','action':{'kind': …}}))`.

## B. Terminal rows

- [ ] B1. New widget `lib/widgets/herdr_terminal_rows.dart` exporting
      `HerdrTerminalRows extends StatelessWidget`, taking `herdr` plus an
      `onOpenWorkspaces` callback (to open the drawer).
- [ ] B2. `build` returns `SizedBox.shrink()` unless
      `herdr.canControl && herdr.workspaces.isNotEmpty`. This is the single
      gate that satisfies R1 and R5.
- [ ] B3. Tab row: horizontal `SingleChildScrollView` of `ChoiceChip`s, one per
      `herdr.visibleTabs`, labelled `t.label` (fall back to `t.number`). Hidden
      entirely when there are ≤ 1. Selected chip = `t.focused`. Tap →
      `herdr.focusTab(t.tabId)`.
- [ ] B4. Pane row: same shape over `herdr.panes(workspaceId).where(pane.tabId
      == focusedTab.tabId)`, labelled by `pane.name ?? pane.terminalTitle ??
      pane.paneId`, with a leading status dot coloured from `pane.agentStatus`
      (reuse the existing status colour mapping; if it lives in a deleted file,
      move that helper into this one). Hidden when ≤ 1. Tap →
      `herdr.focusPane(pane.paneId)`.
- [ ] B5. When a workspace has ≤ 1 tab, the pane row must still resolve a
      workspace id for its query (use `herdr.selectedWorkspaceId`).
- [ ] B6. Show `herdr.error` as a dismissible inline strip below the rows when
      non-null; keep it to one line.

## C. Wire the terminal screen

- [ ] C1. `lib/screens/session_screen.dart`: add optional
      `final HerdrController? herdr;` to `SessionScreen`, defaulted to null so
      existing constructions and tests keep compiling.
- [ ] C2. In the terminal branch of `build` (around line 221), wrap the existing
      `TerminalPane` in a `Column` with `HerdrTerminalRows` **above** it, and
      `Expanded` around the pane. When `herdr == null` render the pane exactly
      as today (no `Column` indirection that could change layout).
- [ ] C3. `initState`: if `widget.herdr != null && widget.herdr.canControl`,
      call `widget.herdr.refresh()` once. Guard against a second call on rebuild.
- [ ] C4. `HomeScreen._open`: pass `herdr: _herdr` into `SessionScreen` for the
      terminal-kind branch only.

## D. Drawer workspace list

- [ ] D1. `lib/widgets/workspace_sidebar.dart`: below the `Herdr 工作区`
      destination, render a nested list of `herdr.workspaces` (dense
      `ListTile`s, leading agent-status dot, title = label, trailing focused
      check icon). Hide the whole block when `!herdr.canControl`.
- [ ] D2. Tapping one calls `herdr.selectWorkspace(id)` and closes the drawer.
      It must not push a route.
- [ ] D3. Keep the existing enable/disable logic (`canBrowse` for the
      destination) untouched.

## E. Remove the snapshot stack

- [ ] E1. Delete `lib/screens/herdr_pane_screen.dart` and
      `lib/widgets/herdr_pane_viewport.dart`.
- [ ] E2. Delete the pane-detail push in `lib/screens/herdr_screen.dart` and any
      row that navigated to it. If `HerdrScreen` becomes unreachable, delete it
      and its `_openHerdr` wiring too; otherwise keep it as a read-only overview
      and update its tile taps to `herdr.selectWorkspace`.
- [ ] E3. Grep for the deleted symbols before committing:
      `Select-String -Path lib\**\*.dart -Pattern "HerdrPaneScreen|HerdrPaneViewport|HerdrViewportMode"`.
      Zero hits required.
- [ ] E4. Delete the corresponding tests in `test/herdr_test.dart` (viewport
      modes, pane switcher group) and keep the rest.

## F. Tests

- [ ] F1. Rows absent when Herdr is unavailable: pump a terminal session with a
      controller whose `herdr_info` fails, expect no `ChoiceChip` in the
      terminal area.
- [ ] F2. Rows present when available: script `herdr_info` ok + two workspaces +
      two tabs + two panes, expect the tab and pane labels.
- [ ] F3. Tapping a pane chip sends `herdr_action` with
      `kind: pane_focus, paneId: wJ:p2` and no other kind.
- [ ] F4. Tapping a tab chip sends `kind: tab_focus`; the pane row then lists
      the new tab's panes (script a second `herdr_panes` reply).
- [ ] F5. Drawer: tapping a workspace sends `kind: workspace_focus` and does not
      push a route.
- [ ] F6. ≤1 tab and ≤1 pane → neither row renders, and the terminal still gets
      full height (assert on the absence of the chip row, not on pixel heights).

## G. Verify

- [ ] G1. `flutter analyze` → no issues.
- [ ] G2. `flutter test` → all green, count recorded before/after.
- [ ] G3. Build + install + launch on the 14u device.
- [ ] G4. Manual on device: open a terminal, run `herdr`, confirm both rows
      appear and a tap moves desktop focus (`herdr pane current` check).

## Review gates

- **Gate A (after A)**: focus is derived from the wire, not stored twice.
- **Gate B (after C)**: terminal with no Herdr is unchanged — diff the widget
  tree in a test rather than eyeballing it.
- **Gate C (after E)**: zero references to the snapshot stack remain.
- **Gate D (after G)**: analyze + tests green, device verified by the user.
