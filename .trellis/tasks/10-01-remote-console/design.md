# Design: additive PTY sessions

Keep the authenticated opaque relay unchanged. Add node-pty with an injectable adapter for tests and a TerminalSession alongside the existing Claude Session. Keep shared session list/subscriptions/lifecycle. Terminal creation validates cwd and session limits; terminal input is raw text, never trimmed or interpreted as an AI prompt.

## Wire contract
- SessionInfo: optional `kind: claude | terminal`, `cols`, `rows`; missing kind means claude.
- info: optional `capabilities: string[]`, containing `terminal` when PTY is available.
- create_terminal: `{cwd, cols?, rows?}` returns existing session_created.
- terminal_input: `{sessionId, data}` exact UTF-8 input.
- terminal_resize: `{sessionId, cols, rows}` validates integer geometry.
- EventBody: `{kind: terminal_output, data: string}`; existing seq/ts and events.reset are retained.
- interrupt sends Ctrl-C for PTY; close terminates PTY. Claude permission/mode/send requests reject terminal sessions.

Flutter uses xterm terminal emulator for ANSI, cursor movement and alternate screen. SessionView owns replay revision/reset tracking; terminal view processes each event once and resets emulator on server reset. Input/control keys and resize are sent through RemoteController with visible errors. New-session UI defaults to terminal when capability exists and preserves Claude selection. Unknown fields remain compatible.

Desktop --terminal option starts a PTY, mirrors output to local stdout, forwards raw stdin and terminal resize, while retaining relay access. Pairing/log output must not corrupt the terminal once attached; local detach swaps input handlers while keeping raw mode on Windows to avoid EPIPE; final shutdown restores normal input mode. PTY privileges equal the desktop user; --root is not a sandbox. Tests use injected PTY plus a real shell smoke.

## Change boundary
Server protocol/core/session integration and CLI own process lifecycle. Flutter models/controller/session view/screens own mobile rendering. README/task records/specs describe the final contract. No relay redesign or provider-specific adapters are needed.

## Authorized follow-up
See [desktop-integration.md](desktop-integration.md) for the 2026-10-03 requested easy deployment and Codex Desktop sidebar/control scope. Previous completion applies only to the terminal baseline; this follow-up remains in progress.
