# Terminal session contract

## Scope and ownership
`server/src/shared/protocol.ts` owns wire types; `lib/models/protocol.dart` mirrors them. AgentCore shares authenticated subscriptions and lifecycle between Claude Session and TerminalSession. The relay does not interpret terminal payloads. `pty.ts` is the native adapter; deterministic tests inject PtyFactory.

## Requests and replies
- `info` adds optional `capabilities: ["terminal"]` only when a PTY factory is configured.
- `create_terminal {cwd, cols?, rows?}` returns `session_created {id, session}`. Default geometry is 80x24.
- `terminal_input {sessionId, data}` passes exact text to PTY. Never trim, append newline or reinterpret it as a Claude prompt. Input limit is 64 KiB UTF-8.
- `terminal_resize {sessionId, cols, rows}` accepts integer columns 2..500 and rows 1..300.
- Shared `subscribe {sessionId, afterSeq?}` returns `events {id, sessionId, events, reset}`; live `event` follows. Every `terminal_output` has `data`, monotonic `seq`, and `ts`.
- Session metadata adds `kind: "terminal"`, `cols`, `rows`. Missing kind remains legacy Claude.
- `interrupt` sends Ctrl-C; `close_session` terminates the child. Client disconnection only removes subscriptions.

## Validation and failures
| Input | Behavior |
| --- | --- |
| Missing PTY capability | create_terminal returns correlated error |
| cwd outside roots / nonexistent directory | correlated error before spawning |
| Invalid geometry / oversized input | correlated error, no PTY operation |
| Claude send / mode / permission on terminal | correlated error |
| Raw terminal input on Claude session | correlated error |
| Closed terminal | further input/resize rejected |
| Sequence beyond current or older than retained output | reset plus bounded retained replay |

`--root` constrains directory selection, not shell privileges. All paired clients possess desktop execution rights. Do not label terminal mode as sandboxed.

## Replay and resources
Keep terminal data verbatim, split large output frames without splitting surrogate pairs, and bound retained output by both count and UTF-8 bytes. Current limits are 2000 events and 256 KiB. JSON escaping adds overhead: test serialized replay against MAX_FRAME_BYTES. Start truncated replays only at safe ANSI boundaries; reconstruction after eviction remains best effort, not an exact screen snapshot.

`lib/state/session_view.dart` owns the emulator and sequence cursor across navigation, limits terminal scrollback, and suppresses emulator-generated device replies while applying replay. A reset creates a fresh emulator. Live input must be disabled while disconnected or closed; never queue keystrokes to replay as commands after reconnect.

## Cases and tests
- Base: default shell, output, input, resize, close.
- Good: ANSI + Unicode output is byte-preserved; reconnect requests last sequence, app deduplicates; desktop and phone observe same process.
- Bad: malformed input, geometry, cwd or cross-kind commands return errors with original request id.
- Required: fake PTY lifecycle/replay boundary tests, real native shell input/output/exit, Flutter controller and widget checks, Dart-to-Node integration.

Wrong: `session.send(data.trim())`. Correct: `terminal.write(data)` after validating terminal type and byte limit.

## Windows native lifecycle
Pin node-pty and re-run real process tests when upgrading. The adapter uses normal ConPTY on Windows and isolates a version-specific cleanup workaround in pty.ts: enumerate attached console processes before public kill, cache that result on the instance to avoid enumeration/destruction races, and dispose the output worker on natural exit. No global prototypes or SDK caches are changed. Public kill still releases the native console and child processes. AgentCore.closeAll returns Promise<void>; shutdown entrypoints must await it. Natural exit must let the test runner exit without force-exit.

Desktop --terminal mode keeps stdin raw across detach/reattach and restores it at agent shutdown. Switching raw mode off/on while a Windows read is pending caused EPIPE. Detach changes the input listener and restores the main screen; it does not stop the child. Real desktop tests cover local echo, relay control, detach, reattach and shutdown.
