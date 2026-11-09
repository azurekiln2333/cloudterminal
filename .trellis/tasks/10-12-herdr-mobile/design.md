# Design — Herdr integration

## 1. Boundary choice: why the CLI, not the raw socket

Herdr exposes a private socket at `D:\AppData\Roaming\herdr\herdr.sock`
(protocol 22). Its framing is undocumented; only `herdr api schema` describes it,
and the schema is a 272 KB generated document with no compatibility promise to
third parties. Its own `status` output labels it `private_protocol`.

The `herdr` CLI is the **documented, supported, versioned** surface, and every
command we need already prints structured JSON. Therefore:

- The desktop agent shells out to the `herdr` binary and parses JSON.
- The private socket protocol is not implemented.
- `herdr.status` is parsed from the text output only for availability reporting.

Tradeoff: one process spawn per operation (~30–60 ms here) instead of a
persistent socket. Accepted: Herdr control is interactive-rate, not streaming, and
not spawning means no protocol-version coupling to a private API.

## 2. Layering

```
phone (Flutter)                desktop agent (Node/TS)              Herdr
────────────────               ───────────────────────              ─────
RemoteController  ──relay──▶   AgentCore.dispatch()
  .herdrListWorkspaces()          └─ HerdrBridge.call(group, args)
  .herdrListAgents()                    └─ HerdrRunner(argv, timeout) ──▶ herdr.exe
  .herdrRead(...)                              ◀── single JSON object
  .herdrAct(...)                              or raw text for *read
        ◀── AgentMessage {kind:'herdr_*'} ──
```

New module `server/src/agent/herdr.ts` owns:

- `HerdrRunner` — injectable `(argv: string[], timeoutMs) => Promise<HerdrResult>`.
  Production implementation `nativeHerdrRunner` uses `child_process.spawn` with an
  **argv array, `shell:false`**, resolved binary path, capped stdout, hard timeout
  and process kill. Tests inject a fake.
- `HerdrBridge` — discovery, validation, and the typed operations. Depends only on
  the runner, so it is fully testable without Herdr installed.

`AgentCore` gains an optional `herdr?: HerdrBridge`, exactly like the existing
optional `codex?: CodexBridge`. Absent bridge → typed `herdr_unavailable` error
and no `herdr` capability advertised.

## 3. Binary resolution and availability

Resolution order, first hit wins:

1. `CLOUDTERMINAL_HERDR_PATH` (explicit override; useful for tests/CI).
2. `config.herdrPath` from `agent.json` (persisted by `--herdr-path`).
3. `herdr` on `PATH` (`where`/`which` resolution done by `spawn` + `PATH` scan).
4. Known install locations probed once per process: `%ProgramFiles%\herdr-windows-*`,
   `$HOME/.local/bin/herdr`, `/usr/local/bin/herdr`, `/opt/homebrew/bin/herdr`.

Availability probe (cached ~10 s, invalidated on forced refresh):

- `herdr --version` → must match `^herdr\s+(\S+)`.
- `herdr status` → parse `server.status`, `server.socket`, `client.protocol`.

Result:

```ts
type HerdrAvailability = {
  available: boolean;      // binary found AND server reachable
  installed: boolean;      // binary found (even if server down)
  version?: string;        // "0.9.3"
  protocol?: number;       // 22
  socket?: string;
  serverRunning: boolean;
  canControl: boolean;     // available === true
  reason?: string;         // actionable Chinese message when not controllable
};
```

Distinct reasons (these drive R7):

| Condition | `reason` shown on the phone |
| --- | --- |
| binary missing | `这台电脑没有安装 Herdr。安装后重启 agent 即可看到工作区。` |
| binary present, server stopped | `Herdr 服务未运行。请在电脑上打开一次 Herdr 或运行 herdr server。` |
| version unparsable | `Herdr 已安装但无法确认版本，请升级到 0.9 以上。` |
| any call fails mid-way | `Herdr 无响应：<message>` |

## 4. Argument construction and validation

Every operation is expressed as a **fixed argv shape** with validated slots. No
string is ever concatenated into a command line and `shell` is always `false`.

Validators (all reject with a Chinese message naming the bad value):

| Slot | Rule |
| --- | --- |
| workspace id | `^w[0-9A-Za-z]{1,8}$` |
| tab id | `^w[0-9A-Za-z]{1,8}:t[0-9]+$` |
| pane id | `^w[0-9A-Za-z]{1,8}:p[0-9]+$` |
| agent target | pane id, **or** `^[a-z][a-z0-9_-]{0,31}$` |
| agent name (create) | `^[a-z][a-z0-9_-]{0,31}$` (Herdr's own rule) |
| agent kind | must be one of Herdr's 24 listed kinds |
| direction | `left\|right\|up\|down` |
| read source | `visible\|recent\|recent-unwrapped\|detection` |
| lines | integer `1..5000` |
| ratio | `0.05..0.95` |
| zoom mode | `toggle\|on\|off` |
| label | ≤ 120 chars, no control chars (`\x00-\x1f\x7f`) |
| prompt text | free text, but NUL-stripped; ≤ 64 KB; never shell-interpreted |
| logical key | **allowlist** (below) |
| key repeat | 1..50 |

Logical key allowlist (superset of what the official skill uses, restricted to
non-destructive control keys): `enter esc tab backspace space up down left right
home end pageup pagedown ctrl+a ctrl+c ctrl+d ctrl+l ctrl+r ctrl+u ctrl+z
shift+tab`. `pane run` is **not** allowlisted by key — it is a separate, explicit
operation whose command string is passed as a single argv element.

## 5. Wire protocol additions

All additive; `PROTOCOL_VERSION` stays `1` (the contract is append-only, and both
sides already ignore unknown kinds/types).

### ClientRequest (phone → desktop agent)

```ts
| { type: 'herdr_info' }
| { type: 'herdr_workspaces' }
| { type: 'herdr_tabs'; workspaceId: string }
| { type: 'herdr_panes'; workspaceId: string }
| { type: 'herdr_agents' }
| { type: 'herdr_agent'; target: string }
| { type: 'herdr_layout'; paneId: string }
| { type: 'herdr_read'; paneId: string; source?: HerdrReadSource; lines?: number }
| { type: 'herdr_prompt'; target: string; text: string; wait?: boolean; timeoutMs?: number }
| { type: 'herdr_send_text'; paneId: string; text: string }
| { type: 'herdr_send_keys'; target: string; keys: string[]; repeat?: number }
| { type: 'herdr_run'; paneId: string; command: string }
| { type: 'herdr_wait'; target: string; until?: HerdrAgentStatus[]; timeoutMs?: number }
| { type: 'herdr_act'; action: HerdrAction }
```

`HerdrAction` is a discriminated union so one dispatcher can cover the whole
lifecycle table:

```ts
type HerdrAction =
  | { kind: 'workspace_create'; label?: string; cwd?: string; focus?: boolean }
  | { kind: 'workspace_rename'; workspaceId: string; label: string }
  | { kind: 'workspace_focus'; workspaceId: string }
  | { kind: 'workspace_close'; workspaceId: string; group?: boolean }
  | { kind: 'tab_create'; workspaceId: string; label?: string; cwd?: string; focus?: boolean }
  | { kind: 'tab_rename'; tabId: string; label: string }
  | { kind: 'tab_focus'; tabId: string }
  | { kind: 'tab_close'; tabId: string }
  | { kind: 'pane_split'; paneId: string; direction: 'right'|'down'; ratio?: number; cwd?: string; focus?: boolean }
  | { kind: 'pane_focus'; paneId: string }
  | { kind: 'pane_zoom'; paneId?: string; mode: 'toggle'|'on'|'off' }
  | { kind: 'pane_rename'; paneId: string; label?: string }
  | { kind: 'pane_close'; paneId: string }
  | { kind: 'pane_resize'; paneId: string; direction: 'left'|'right'|'up'|'down'; amount?: number }
  | { kind: 'pane_move'; paneId: string; to: 'new_tab'|'new_workspace'|'tab'; tabId?: string; split?: 'right'|'down'; label?: string }
  | { kind: 'agent_start'; name: string; agentKind: string; paneId: string; args?: string[] }
  | { kind: 'agent_rename'; target: string; name?: string }
  | { kind: 'agent_focus'; target: string };
```

### AgentMessage (desktop agent → phone)

```ts
| { kind: 'herdr_info'; id?: string; availability: HerdrAvailability }
| { kind: 'herdr_workspaces'; id?: string; workspaces: HerdrWorkspace[] }
| { kind: 'herdr_tabs'; id?: string; workspaceId: string; tabs: HerdrTab[] }
| { kind: 'herdr_panes'; id?: string; workspaceId: string; panes: HerdrPane[] }
| { kind: 'herdr_agents'; id?: string; agents: HerdrAgent[] }
| { kind: 'herdr_agent'; id?: string; agent: HerdrAgent }
| { kind: 'herdr_layout'; id?: string; layout: HerdrLayout }
| { kind: 'herdr_output'; id?: string; paneId: string; source: HerdrReadSource; text: string }
| { kind: 'herdr_result'; id?: string; action: string; summary: string; data?: unknown }
```

Shared value types (string-literal unions for status, so a future Herdr status
degrades to `unknown` instead of throwing):

```ts
type HerdrAgentStatus = 'idle' | 'working' | 'blocked' | 'done' | 'unknown';
type HerdrReadSource = 'visible' | 'recent' | 'recent-unwrapped' | 'detection';

type HerdrWorkspace = {
  workspaceId: string; label: string; number: number; focused: boolean;
  agentStatus: HerdrAgentStatus; paneCount: number; tabCount: number; activeTabId?: string;
};
type HerdrTab = {
  tabId: string; workspaceId: string; label: string; number: number;
  focused: boolean; agentStatus: HerdrAgentStatus; paneCount: number;
};
type HerdrPane = {
  paneId: string; workspaceId: string; tabId: string; cwd: string;
  focused: boolean; terminalTitle: string; agent?: string;
  agentStatus?: HerdrAgentStatus; name?: string; interactiveReady?: boolean;
  scroll?: { offsetFromBottom: number; maxOffsetFromBottom: number; viewportRows: number };
};
type HerdrAgent = {
  target: string;      // name when set, else paneId — what to send commands to
  paneId: string; workspaceId: string; tabId: string; cwd: string;
  agentKind: string; status: HerdrAgentStatus; focused: boolean;
  name?: string; terminalTitle: string; interactiveReady?: boolean;
  completionSeq?: number; stateChangeSeq?: number;
};
type HerdrLayout = {
  workspaceId: string; tabId: string; zoomed: boolean; focusedPaneId?: string;
  area: { x:number; y:number; width:number; height:number };
  panes: { paneId: string; focused: boolean; rect: {...} }[];
  splits: { id: string; direction: string; ratio: number }[];
};
```

### Error codes

Herdr errors are normalised into the existing `{kind:'error', message}` channel
with a stable prefix so the app can branch without parsing prose. The message
carries the actionable Chinese text; the raw code is appended for diagnostics:

```
herdr_unavailable:<reason>
pane_not_found:<message>
agent_not_found:<message>
agent_not_ready:<message>
agent_blocked:<message>
agent_prompt_stalled:<message>
timeout:<message>
invalid_argument:<message>
```

`herdr_prompt_stalled` and `timeout` are returned as **errors that the UI must
show without retrying**, per research finding #3. To make that enforceable, the
`herdr_prompt` handler never retries internally and the app disables its send
button until the request settles.

## 6. Dispatch and fan-out

`herdr_*` requests are handled in `AgentCore.dispatch` by delegating to
`HerdrBridge`. They are request/response only — no subscriptions. Rationale:

- Pane content is read on demand with an explicit source and line count; a push
  stream would need its own backpressure, replay and seq accounting, and Herdr
  gives us no change feed over the CLI.
- Reconnect recovery is already handled by `RemoteController._refreshAfterConnect`;
  Herdr listings refresh there too.
- The existing `markDirty`/`SessionInfo` plumbing stays untouched, so terminal and
  Claude session behaviour is bit-for-bit unchanged.

Live "refresh" in the UI is therefore an explicit user action (pull-to-refresh /
refresh button) plus an automatic refresh after any mutating action.

## 7. Flutter design

New files (all additive):

```
lib/models/herdr.dart            typed Herdr models + lenient JSON parsing
lib/state/herdr_controller.dart  listing cache, actions, in-flight guard
lib/screens/herdr_screen.dart    workspaces → tabs → panes → agents
lib/screens/herdr_pane_screen.dart  output viewer + input bar + controls
```

`RemoteController` gains thin typed passthroughs (`herdrWorkspaces()`,
`herdrAgents()`, `herdrRead()`, `herdrPrompt()`, `herdrAct()` …) that reuse
`_request`, so timeout/correlation/reconnect behaviour is inherited unchanged.

Navigation: `WorkspaceSidebar` gains a `Herdr` destination above the existing
`终端与 Claude` entry. When Herdr is unavailable the entry is present but
disabled with the availability reason inline — truthful, not hidden. Deep links
into `herdr_screen.dart` reuse the same `Navigator` and `navigationButton` pattern
as `CodexScreen`, and the drawer/wide-layout behaviour is identical to today, so
primary navigation is preserved.

`HerdrController` holds:

- `availability`, `workspaces`, `agents` (per-workspace pane/tab caches)
- `loading`, `error` per list
- a single `Set<String> _inFlight` action guard → the UI disables the matching
  button, which is the duplicate-agent/duplicate-submit defence required by R4.
- `refreshAll()` used after login, reconnect, pull-to-refresh and after every
  successful mutation.

`herdr_pane_screen.dart` renders text output in a monospace scroll view with a
source selector (`可见屏幕` / `最近输出` / `最近输出(去折行)`) and a line-count
selector, an input bar offering **发送给 agent** (when the pane hosts an agent) vs
**发送到终端**, and a controls sheet limited to actions valid for that pane's
state. Every destructive action (close workspace/tab/pane) goes through a
confirmation dialog that names the target.

## 8. Non-regression strategy

- `herdr` is an optional constructor dependency; with it absent, `AgentCore`
  behaves exactly as before (the `codex` bridge pattern).
- New protocol entries are additive; existing union members are untouched, so all
  existing switch statements stay exhaustive except `AgentCore.dispatch`'s
  `default` throw (which now catches `herdr_*` before it) and the Dart `_onMessage`
  switch (already `default`-less and kind-based).
- Dart `SessionEvent.fromJson` already falls back to `UnknownEvent`, so no change.
- `workspace_sidebar.dart` only gains entries; existing indices 0/1 keep their
  meaning (`onDestinationSelected` maps 0→home, 1→history, Herdr is a separate
  tappable `ListTile`-style destination rather than shifting indices).

## 9. Rollback

The feature is one bridge + additive protocol. Rollback = remove
`new HerdrBridge(...)` from `agent/main.ts` and the sidebar entry; no persisted
state migration, no data written to Herdr, no agent identity change. `.build/`
artifacts are gitignored coordination files.

## 10. Isolation policy for tests

- Automated: injected `HerdrRunner` fake — never spawns Herdr, never touches state.
- Real smoke test (manual/t scripted, opt-in): creates a workspace with a random
  label `ct-probe-<hex>`, asserts it appears in `workspace list`, then
  `workspace close` it and asserts it disappears. Reruns first sweep for leftover
  `ct-probe-*` labels from previous runs. It never focuses, renames or closes a
  pre-existing workspace, and never starts an agent.
