# Completion audit — Herdr mobile control

Evidence is current source, tests and recorded real-CLI output, not task status.

| Requirement | Evidence | Status |
| --- | --- | --- |
| R1 real integration, optional | `server/src/agent/herdr.ts` spawns the installed CLI; missing binary / stopped server → `herdr_unavailable` with a Chinese reason; capability only when available | Proven |
| R2 workspace/agent discovery | `workspace list` / `tab list` / `pane list` / `agent list` mapped in `herdr.ts`; `AgentCore` routes `herdr_*`; `/tmp` probe and smoke parse real shapes | Proven |
| R3 real state and output | `pane read` returns raw text for `visible`/`recent`/`recent-unwrapped`; live probe read `wJ:p2`; error envelope no longer leaks as output | Proven |
| R4 input and task submission | `agent prompt` (text + Enter, one argv element), `pane send-text`, allowlisted `send-keys`, `pane run`; `_inFlight` guard blocks duplicate submit; stalled/timeout never auto-retried | Proven |
| R5 lifecycle, truthful scope | Discriminated `HerdrAction` covers create/rename/focus/close, split/zoom/resize/move, agent start/rename/focus; attach/takeover documented unsupported | Proven |
| R6 safety | Every value validated server-side; argv arrays with `shell:false`; behind pairing + relay auth; tests use an injected runner; smoke touches only `ct-probe-*` | Proven |
| R7 robustness and errors | Distinct codes/messages for missing binary, stopped server, `pane_not_found`, `agent_not_found`, `agent_not_ready`, `agent_blocked`, `agent_prompt_stalled`, `timeout`; other features unaffected when Herdr is off | Proven |
| R8 non-regression | `herdr` is an optional `AgentCore` dependency; absent ⇒ identical behaviour; wire additions are append-only; baseline Flutter tests still pass | Proven |
| R9 verification | `npm run check` clean, `npm test` 97/97, `flutter analyze` clean, `flutter test` 68/68 incl. Dart↔Node Herdr test; real smoke recorded | Proven |
| Acceptance 7: device runtime | No device attached | **Unverified** |

## Bugs fixed this session

1. `test/herdr_test.dart` would not compile — imported `shared_preferences` (not a
   dependency) and called non-existent `AppStore.load()` /
   `toJsonKeys()`. Switched to `AppStore.memory()` and added real `toJson()` maps.
2. `pane read` failure leaked a JSON `{"error":…}` envelope as pane text; now
   raised as a typed `HerdrError`, with regression tests.

## Limits kept explicit

- Local Herdr server only; no interactive TUI takeover, no `--machine`/`--remote`.
- Polling/refresh, not a push stream.
- Native runtime verified on Windows with Herdr 0.9.3.
- Device/APK rendering not run; phone-on-device is unverified.
