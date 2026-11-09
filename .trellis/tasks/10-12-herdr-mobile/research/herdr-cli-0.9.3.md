# Herdr 0.9.3 — real local capabilities (probed 2026-10-12)

Binary: `D:\ProgramFiles\herdr-windows-x86_64\herdr.exe`
Version: `herdr 0.9.3`
Config: `D:\AppData\Roaming\herdr\config.toml`
Socket: `D:\AppData\Roaming\herdr\herdr.sock`
Logs: `D:\AppData\Roaming\herdr\herdr.log`, `herdr-client.log`, `herdr-server.log`

## Invocation contract

`herdr <group> <subcommand> [args]` returns a single JSON object on **stdout**:

```json
{"id":"cli:workspace:get","result":{"type":"workspace_info","workspace":{...}}}
```

- Success → `{"result": {...}}`, exit code `0`.
- Failure → `{"error":{"code":"pane_not_found","message":"pane wZ:p9 not found"},"id":"cli:pane:get"}`, exit code `1`.
- Usage error → plain-text usage on stderr, exit code `2`.
- **`pane read` / `agent read` are the exception**: they print raw screen text, not JSON.
- There is no global `--json` flag; JSON is the default for structured commands.
- Only `machine list|status`, `session list|stop|delete` and `agent explain` accept `--json`
  (they default to human text).

`herdr status` output is YAML-ish text, not JSON:

```
client:
  version: 0.9.3
  channel: stable
  protocol: 22
server:
  status: running
  version: 0.9.3
  endpoint_compatible: yes
  socket: D:\AppData\Roaming\herdr\herdr.sock
```

`herdr api snapshot` returns the whole live session snapshot
(`{result:{snapshot:{protocol,workspaces[],tabs[],panes[],agents[],layouts[]}}}`) in one
call — useful for a bulk refresh, 50 KB+ on this machine.

`herdr api schema --output PATH` writes a 272 KB JSON schema.

## Command groups relevant to this task

```
herdr api snapshot | schema [--json|--output PATH]
herdr workspace list | create [--cwd PATH] [--label TEXT] [--env K=V] [--focus|--no-focus]
                | get <id> | focus <id> | rename <id> <label> | close <id> [--group]
                | report-metadata <id> --source ID [...]
herdr tab list [--workspace ID] | create [--workspace ID] [--cwd PATH] [--label TEXT]
          | get <id> | focus <id> | rename <id> <label> | close <id>
herdr pane list [--workspace ID] | current [--pane ID|--current] | get <id>
           | layout [--pane ID|--current] | process-info | neighbor | edges
           | focus --direction D | resize --direction D [--amount F] | zoom [id] [--toggle|--on|--off]
           | rename <id> <label>|--clear
           | read <id> [--source visible|recent|recent-unwrapped] [--lines N] [--format text|ansi]
           | split [<id>|--current] --direction right|down [--ratio F] [--cwd P] [--focus|--no-focus]
           | swap | move <id> (--tab ID --split D | --new-tab | --new-workspace) [...]
           | close <id> | send-text <id> <text> | send-keys <id> <key>...
           | run <id> <command> | wait-output <id> (--match T|--regex P) [...]
           | report-agent | report-agent-session | release-agent | report-metadata
herdr agent list | get <target> | read <target> [--source S] [--lines N] [--format text|ansi]
            | send-keys <target> <key>... | prompt <target> <text> [--wait] [--until S] [--timeout MS]
            | rename <target> <name>|--clear | focus <target> | wait <target> [--until S] [...]
            | attach <target> [--takeover] | start <name> --kind KIND --pane ID [--timeout MS] [-- args]
            | explain <target>
herdr workspace|tab|pane|agent  (run the group alone to print its command list)
herdr session list [--json] | stop <name> [--json] | delete <name> [--json]
herdr server stop | reload-config
herdr notification show <title> [--body T] [--position P] [--sound S]
herdr worktree list|create|open|remove ...
herdr integration install|uninstall|status
herdr machine list|status|add|remove|enable|disable|rename|reconnect
herdr config check | reset-keys
herdr channel show | set <stable|preview>
```

Agent kinds (from `herdr agent`):
`pi|claude|codex|gemini|cursor|devin|agy|cline|omp|mastracode|opencode|copilot|kimi|kiro|droid|amp|grok|hermes|kilo|qodercli|qwen|letta|maki|muse`

Agent targets accept **a unique live agent name** or **the pane id currently hosting
that agent**. NOT terminal ids, NOT bare kind labels.

Agent names must match `[a-z][a-z0-9_-]{0,31}` and be unique among live agents.

## Live data shapes

### `herdr workspace list`

```json
{"id":"cli:workspace:list","result":{"type":"workspace_list","workspaces":[
  {"workspace_id":"wJ","label":"cloudterminal","number":13,"focused":true,
   "agent_status":"working","pane_count":2,"tab_count":1,"active_tab_id":"wJ:t1"}
]}}
```

`agent_status` ∈ `idle|working|blocked|done|unknown`.

### `herdr tab list`

```json
{"result":{"type":"tab_list","tabs":[
  {"tab_id":"wJ:t1","workspace_id":"wJ","label":"1","number":1,
   "focused":true,"agent_status":"working","pane_count":2}
]}}
```

### `herdr pane list` / `pane get` / `agent get`

```json
{"pane_id":"wJ:p2","workspace_id":"wJ","tab_id":"wJ:t1","focused":false,
 "cwd":"D:\\MyNewProjects\\cloudterminal","revision":3,
 "terminal_id":"term_65d95862e3eb324",
 "terminal_title":"π - cloudterminal","terminal_title_stripped":"π - cloudterminal",
 "agent":"pi","agent_status":"idle","completion_seq":430,
 "agent_session":{"agent":"pi","kind":"path","source":"herdr:pi",
                  "value":"C:\\Users\\...\\session.jsonl"},
 "scroll":{"max_offset_from_bottom":0,"offset_from_bottom":0,"viewport_rows":43}}
```

Optional fields seen live: `name` (only when explicitly named),
`interactive_ready`, `screen_detection_skipped`.

### `herdr pane layout`

```json
{"result":{"type":"pane_layout","layout":{
  "workspace_id":"wJ","tab_id":"wJ:t1","zoomed":false,
  "focused_pane_id":"wJ:p1",
  "area":{"x":0,"y":0,"width":153,"height":45},
  "panes":[{"pane_id":"wJ:p1","focused":true,"rect":{"x":0,"y":0,"width":77,"height":45}}],
  "splits":[{"id":"split_0_root","direction":"right","ratio":0.5,"rect":{...}}]}}}
```

### `herdr pane read` / `agent read`

Raw text. `--source visible|recent|recent-unwrapped|detection`;
`--lines N` pulls from screen + host scrollback; `--format ansi` keeps styling.

### `herdr session list --json`

```json
{"sessions":[{"default":true,"name":"default","running":true,
  "session_dir":"D:\\AppData\\Roaming\\herdr",
  "socket_path":"D:\\AppData\\Roaming\\herdr\\herdr.sock"}]}
```

## Error codes observed

| code | trigger |
| --- | --- |
| `pane_not_found` | `pane get wZ:p9` |
| `agent_not_found` | `agent get nope` |
| `agent_not_ready` | `agent start` returns early while the agent is still booting (the name stays usable) |
| `agent_blocked` | `agent prompt` against an agent sitting at an approval/question dialog; rejected **before** any input is written |
| `agent_prompt_stalled` | `prompt --wait` saw no `working`/`blocked` activity within 5 s |
| `timeout` | caller timeout expired |
| usage text, exit 2 | malformed invocation |

## Semantics that shape the design

1. **`idle` and `done` both mean ready for input.** `done` is a "finished, unseen"
   marker driven by the server's seen state; `blocked` means an approval/question
   UI is up; `unknown` means an agent is present but unclassifiable.
2. **`agent prompt` already handles paste + Enter ordering** and honors live
   bracketed-paste mode. Sending text and Enter separately over `send-text` +
   `send-keys enter` is a worse path.
3. **A stalled prompt does not prove non-delivery.** Never auto-retry.
4. **`pane split` omitted target uses the caller pane** when `HERDR_PANE_ID` is set
   (the CloudTerminal agent is *not* inside a pane, so an explicit target is
   mandatory for us), otherwise the UI-focused pane.
5. **`agent start` requires an existing available shell pane** and never creates
   layout. Picking a pane whose foreground process is not an idle shell yields
   `agent_not_ready`.
6. **Closed tab/pane ids are never reused.** A pane moved to another workspace gets
   a **new** workspace-qualified pane id.
7. The official `herdr --skill` text instructs an agent to refuse control unless
   `HERDR_ENV=1`, i.e. the agent itself runs inside a Herdr pane. That check exists
   to stop an in-pane agent from hijacking the *user's* focused session by accident.
   CloudTerminal is an explicit, authenticated, user-initiated controller, so it
   talks to the local socket directly; the safeguard is kept in spirit by (a) never
   using an implicit/omitted target, (b) requiring explicit ids from the phone, and
   (c) confirming destructive operations.

## Probe artifacts

- `.build/pi-herdr/herdr-probe/schema.json` — `herdr api schema` output (272 KB)
- `.build/pi-herdr/herdr-probe/snapshot.json` — `herdr api snapshot`
- `.build/pi-herdr/herdr-probe/workspace-list.json`
- `.build/pi-herdr/herdr-probe/agent-list.json`
- `.build/pi-herdr/herdr-probe/tab-list.json`
- `.build/pi-herdr/herdr-probe/pane-list.json`
- `.build/pi-herdr/herdr-probe/pane-get.json`
- `.build/pi-herdr/herdr-probe/agent-get.json`
- `.build/pi-herdr/herdr-probe/layout.json`
- `.build/pi-herdr/herdr-probe/read-wJp2.json` (text output of `pane read`)
