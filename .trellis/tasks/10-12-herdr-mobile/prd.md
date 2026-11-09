# Herdr workspace control from the phone

## Background

CloudTerminal already pairs a phone with a desktop agent through a relay and can
drive raw PTYs, Claude Code sessions and a read-only Codex catalog. The user runs
**Herdr** (`herdr 0.9.3`, `D:\ProgramFiles\herdr-windows-x86_64\herdr.exe`) as the
terminal multiplexer that hosts all of their coding agents: 13 workspaces, ~33
panes, agents of kind `pi` and `codex` in various lifecycle states
(`idle`/`working`/`blocked`/`done`).

Today the app knows nothing about Herdr. The user wants to control Herdr
workspaces and agents from the phone and see the real effect.

## Problem

Herdr already exposes everything the phone needs through a local socket API with
a stable JSON contract (`herdr workspace|tab|pane|agent|api ...`). What is missing
is the bridge: the desktop agent does not talk to Herdr, the wire protocol has no
Herdr messages, and the app has no Herdr UI. The result is that the phone can only
see CloudTerminal's own PTYs, not the agents the user actually works with.

## Requirements

### R1 — Real Herdr integration, not a simulation

- The desktop agent must talk to the **installed** Herdr CLI/socket API. No
  invented endpoints, no sample data, no hardcoded workspace lists.
- Herdr must be optional: when the binary is absent or the server is stopped, the
  agent still starts and reports Herdr as unavailable with an actionable reason.
- Herdr availability (`version`, server status, socket path, protocol) is
  discovered at runtime and surfaced to the phone.

### R2 — Workspace and agent discovery

- The phone lists real Herdr workspaces (label, number, counts, aggregate agent
  status, focused flag) and, per workspace, its tabs and panes.
- The phone lists real agents with kind, name (when set), pane/workspace/tab ids,
  cwd, lifecycle status and whether Herdr considers them interactively ready.
- Pane identity (pane id, terminal title, focused flag, cwd) is available even
  when no agent occupies the pane.

### R3 — Real state and output

- The phone can read a pane's real screen output with a selectable source
  (`visible` / `recent` / `recent-unwrapped`) and line count.
- Reading must never mutate anything.
- Output must be delivered as data and appended/refreshed in the UI, not silently
  truncated into a "sample".

### R4 — Input and task submission

- The phone can send a prompt to a named agent through `agent prompt`
  (text + encoded Enter as one ordered submission). Mobile-controlled text must
  never be interpolated into a shell command line.
- The phone can send raw input to a pane (`pane send-text`) and logical keys
  (`pane send-keys` / `agent send-keys`) from a **validated allowlist**.
- The phone can run an ordinary command in a pane via `pane run`.
- Duplicate submissions must be preventable: the UI disables the send action
  while a request is in flight, and `agent prompt` results that report
  `agent_prompt_stalled` / `timeout` must be surfaced **without** auto-resending.

### R5 — Supported lifecycle controls, truthfully scoped

Supported controls must map onto real Herdr commands, and unsupported ones must
be explained rather than faked:

| Control | Backed by | Notes |
| --- | --- | --- |
| Create workspace | `workspace create` | optional label and cwd |
| Rename workspace | `workspace rename` | |
| Focus workspace | `workspace focus` | |
| Close workspace | `workspace close [--group]` | destructive, needs confirm |
| Create tab | `tab create` | |
| Rename/focus/close tab | `tab rename`/`focus`/`close` | |
| Split pane | `pane split` | direction + optional ratio/cwd |
| Focus/zoom/rename pane | `pane focus`/`zoom`/`rename` | |
| Close pane | `pane close` | destructive, needs confirm |
| Move pane | `pane move` | new tab / new workspace / into tab |
| Resize pane | `pane resize` | |
| Start agent | `agent start` | requires an idle shell pane |
| Rename/focus/wait agent | `agent rename`/`focus`/`wait` | |
| Attach/takeover | **not supported** | interactive TUI takeover is deliberately out of scope |

### R6 — Safety

- All mobile-supplied values (pane ids, workspace ids, labels, keys, commands)
  are validated on the desktop agent before any Herdr invocation.
- No `shell: true`; arguments are passed as an argv array.
- Herdr control stays behind the existing pairing secret and relay authentication.
  Nothing is exposed unauthenticated and no secret is hardcoded.
- Existing user workspaces/agents are never mutated as a test. Automated tests use
  an injected fake Herdr runner plus a dedicated isolated workspace that is
  created and destroyed by the test itself.

### R7 — Robustness and errors

- Missing binary, stopped server, `pane_not_found`, `agent_not_found`,
  `agent_not_ready`, `agent_blocked`, `agent_prompt_stalled` and timeouts each map
  to a distinct, actionable Chinese message for the phone.
- Herdr unreachable mid-session must not break terminal/Claude/Codex features.
- Reconnects must re-list Herdr state rather than assume staleness.

### R8 — Non-regression

- Existing primary navigation (sessions list, Claude/terminal sessions, Codex
  catalog, history, appearance) keeps working. Herdr is an additive destination.
- `PROTOCOL_VERSION` handling stays lenient: an older app against a newer agent
  and vice versa must not crash.

### R9 — Verification

- TypeScript: `npm run check` and `npm test` in `server/` pass.
- Flutter: `flutter analyze` and `flutter test` pass, including a cross-layer
  integration test for the Herdr wire messages.
- Real local Herdr connectivity is demonstrated with recorded command output
  (probe artifacts under `.build/pi-herdr/`), clearly separated from simulated
  tests. Phone-on-device runtime is reported honestly as unverified if no device
  is attached.

## Acceptance criteria

1. `herdr_list_workspaces` returns the real 13 workspaces on this machine with
   correct labels, numbers, counts and focused flag. — **Pass**: smoke and
   `.build/pi-herdr/live-probe-final.txt`.
2. `herdr_list_agents` returns real agents with kind, status, pane id and cwd. —
   **Pass**: 35 agents parsed in the smoke; AgentCore routing test asserts the
   mapped fields.
3. `herdr_read` returns real pane output for `wJ:p2` for all three sources. —
   **Pass**: live probe reads `wJ:p2`; bridge tests cover `visible` /
   `recent` / `recent-unwrapped` and the error envelope.
4. A fresh `create workspace` produces a real new workspace visible in
   `herdr workspace list`, and closing it removes it — no pre-existing workspace
   is touched. — **Pass**: `SMOKE PASSED`, 13 → 13 workspaces.
5. Unsupported/unavailable operations return a typed error with an actionable
   message, never a silent success. — **Pass**: `herdr_unavailable:` /
   `herdr_invalid_argument:` / `herdr_failed:<code>:` prefixes; `pane_not_found`
   surfaced live and in the Dart cross-layer test.
6. `npm run check`, `npm test`, `flutter analyze`, `flutter test` all pass. —
   **Pass**: check clean; 97/97 server tests; analyzer clean; 68/68 Flutter tests.
7. The app's Herdr section lists workspaces and agents and can read live output
   on a device/build. — **Unverified on device** (no device attached).
   Automated widget tests, the analyzer, and the real Dart↔Node WebSocket test
   are the evidence; device rendering is explicitly not claimed.

## Out of scope

- Driving Herdr's interactive TUI from the phone.
- SSH `--machine`/`--remote` forwarding (local server only in this iteration).
- Worktree helpers, notification banners, integration install/uninstall.
- Multi-tenant or unauthenticated Herdr exposure.
