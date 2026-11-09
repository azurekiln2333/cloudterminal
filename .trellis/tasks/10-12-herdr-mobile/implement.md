# Implementation plan — Herdr integration

Artifacts: `prd.md`, `design.md`, `research/herdr-cli-0.9.3.md`.
Validation commands are listed per step; run them before moving on.

## Step 0 — Baseline (record only, do not fix)

- [ ] `cd server; npm run check` — record result.
- [ ] `cd server; npm test` — record result.
- [ ] `flutter analyze` — record result.
- [ ] `flutter test` — record result.

Any pre-existing failure is recorded as baseline and must not be "fixed" by
touching unrelated code. Target: no *new* failures.

## Step 1 — Herdr bridge (server)

- [ ] `server/src/agent/herdr.ts`
  - `HerdrResult` / `HerdrRunner` types + `nativeHerdrRunner` (spawn, argv array,
        `shell:false`, timeout, kill, stdout cap 2 MB, stderr capture).
  - `resolveHerdrBinary()` per design §3 (env → config path → PATH → known dirs).
  - `parseHerdrStatus(text)` for `herdr status` (client/server/protocol/socket).
  - `HerdrBridge`:
    - `availability(force?)` with 10 s cache → `HerdrAvailability`.
    - value-type mappers: `HerdrWorkspace`, `HerdrTab`, `HerdrPane`, `HerdrAgent`,
          `HerdrLayout` — tolerant of missing fields, `agentStatus` clamped to the
          5-value union with `unknown` fallback.
    - `workspaces()`, `tabs(ws)`, `panes(ws)`, `agents()`, `agent(target)`,
          `layout(paneId)`, `read(paneId, source, lines)` (raw text).
    - `prompt(target, text, {wait,timeoutMs})`, `sendText(paneId, text)`,
          `sendKeys(target, keys, repeat)`, `run(paneId, command)`,
          `wait(target, until, timeoutMs)`, `act(action)`.
    - every validator from design §4.
    - error normalisation to the codes in design §5.
- [ ] `server/src/agent/core.ts`: optional `herdr?: HerdrBridge`; handle all
      `herdr_*` requests; add `herdr` capability to `info` only when
      `availability.available`.
- [ ] `server/src/agent/config.ts`: persist optional `herdrPath`.
- [ ] `server/src/agent/main.ts`: `--herdr-path <p>`, `--no-herdr` flags; wire the
      bridge; log availability at startup.
- [ ] `server/src/shared/protocol.ts`: add the client requests, messages and shared
      value types from design §5.

Verify: `cd server; npm run check`

## Step 2 — Server tests

- [ ] `server/test/herdr.test.ts` (fake runner, no real Herdr):
  - availability: missing binary / server stopped / ok — assert the three reasons.
  - listing mappers against the real recorded JSON shapes (copy small fixtures
        from `research/`), including a pane with no agent and a status not in the
        union.
  - **every validator rejects injection attempts**: `w1; rm -rf /`, `w1 && whoami`,
        backticks, newlines, over-long label, bad kind, bad direction, bad source,
        `lines: 0`, `lines: 1e9`, `repeat: 999`.
  - argv shape assertions: `pane split` receives `['pane','split','wJ:p2','--direction','right', ...]`
        as separate array elements; no `shell` usage; a `\n` in prompt text stays in
        one argv element.
  - error mapping: each Herdr error code → normalised code + message.
  - `agent prompt` stalled/timeout is returned as an error and the fake runner is
        called **exactly once** (no retry).
- [ ] `server/test/core.test.ts` (extend): with no bridge → `herdr_*` returns
      `herdr_unavailable` and `info.capabilities` has no `herdr`; with a fake bridge
      → each `herdr_*` request returns the matching message kind.

Verify: `cd server; npm run check; npm test`

## Step 3 — Real local smoke test (opt-in, isolated)

- [ ] `server/scripts/herdr-smoke.ts`:
  - refuse to run unless `CLOUDTERMINAL_HERDR_SMOKE=1`.
  - sweep + close leftover `ct-probe-*` workspaces.
  - create `ct-probe-<hex>` → assert present in `workspace list` → close → assert
        absent. Print each raw Herdr request/response as evidence.
  - never touch a pre-existing workspace; assert the workspace count returns to the
        starting value.
- [ ] Run it: `cd server; $env:CLOUDTERMINAL_HERDR_SMOKE=1; node scripts/herdr-smoke.ts`
      — capture output to `.build/pi-herdr/smoke.txt`.
- [ ] Also capture a read-only live probe: `herdr workspace list`,
      `herdr agent list`, `herdr pane read wJ:p2 --source recent-unwrapped --lines 40`
      into `.build/pi-herdr/live-probe.txt`.

Verify: smoke passes; `herdr workspace list` count unchanged afterwards.

## Step 4 — Flutter models and controller

- [ ] `lib/models/herdr.dart`: mirror design §5 value types + `HerdrAvailability`,
      `HerdrAction` builder, lenient parsing (same style as `protocol.dart`).
- [ ] `lib/state/remote_controller.dart`: typed passthroughs on top of `_request`.
- [ ] `lib/state/herdr_controller.dart`: caches, `refreshAll()`, in-flight action
      guard, per-list loading/error.
- [ ] `test/herdr_models_test.dart`: parse the recorded real shapes; unknown status
      → `unknown`; missing optional fields tolerated; action JSON shape stable.

Verify: `flutter analyze`

## Step 5 — Flutter UI

- [ ] `lib/screens/herdr_screen.dart`: availability banner (with reason) →
      workspace list (label, number, counts, status chip, focused) → tab chips →
      pane list → agents in pane. Create/rename/focus/close workspace; create/focus/
      close tab. Confirmation dialogs for closes.
- [ ] `lib/screens/herdr_pane_screen.dart`: output viewer (source + lines
      selectors, monospace, pull-to-refresh), prompt/input bar, keys row, controls
      sheet (split, zoom, resize, rename, focus, close, start agent).
- [ ] `lib/widgets/workspace_sidebar.dart`: add the Herdr destination; disabled with
      reason when unavailable.
- [ ] `lib/screens/home_screen.dart`: route to `HerdrScreen` preserving the existing
      `Navigator`/drawer pattern.
- [ ] `test/widgets_test.dart` (extend) or new `test/herdr_widgets_test.dart`:
      workspace list renders real fixture data; unavailable state shows the reason
      and a disabled entry; send button disabled while in flight.

Verify: `flutter analyze`

## Step 6 — Cross-layer integration test

- [x] Cross-layer test: `test/node_integration_test.dart` starts a real relay +
      `AgentCore` with a fake Herdr runner (`demo-agent.ts --herdr`) and a real
      WebSocket client: `herdr_info` → `herdr_workspaces` → `herdr_agents` →
      `herdr_panes` → `herdr_read` → `herdr_act(pane_split)` → `herdr_prompt` →
      typed `pane_not_found` error.
- [x] Dart model field names asserted against the TS producer in
      `test/herdr_test.dart` (`toJson()` contract test).

Verify: `cd server; npm test`, `flutter test`

## Step 7 — Docs

- [x] `README.md`: "用手机操控 Herdr 工作区" section — prerequisites,
      `--herdr-path`/`--no-herdr`, capability list, unsupported items, phone steps,
      smoke invocation.
- [x] `.trellis/spec/backend/herdr-protocol.md` and
      `.trellis/spec/frontend/herdr-ui.md`, linked from both index files.

## Step 8 — Quality gate (full scope)

- [x] `cd server; npm run check` — pass
- [x] `cd server; npm test` — 97/97 pass
- [x] `flutter analyze` — no issues
- [x] `flutter test` — 68/68 pass
- [x] `flutter test` — 68/68 pass
- [x] Re-read `prd.md` acceptance criteria 1–7: 1–6 pass with recorded evidence;
      criterion 7 is device runtime and is explicitly **unverified** (no device
      attached). See `completion-audit.md`.

## Step 9 — Finish

- [x] Update `.build/pi-herdr/status.md` and `result.md`.
- [ ] Present a batched commit plan; commit ONLY files added/changed by this task.
      `git status` is dirty with 89 pre-existing changes — never `git add -A`, never
      revert/reset/stash unrelated work.

## Rollback points

- After Step 1: nothing is wired into `main.ts` yet → no behaviour change.
- After Step 3: Herdr state is only read plus one self-created probe workspace.
- Anytime: dropping the sidebar entry and the `new HerdrBridge(...)` line restores
  the previous behaviour; no persisted migration exists.
