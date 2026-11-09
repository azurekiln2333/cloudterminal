# Remote desktop terminal console

## Goal
Continue the existing working Claude console as a general desktop terminal controlled from the phone. The user explicitly authorized continuation and broadened scope on 2026-10-01: arbitrary CLI tools, not only Claude/Codex.

## Requirements
- Preserve pairing, authenticated relay, Claude structured sessions and reconnect.
- Run a real desktop PTY shell supporting arbitrary interactive CLI tools.
- Create terminal sessions from mobile, stream ANSI output, send exact input and control keys, resize and close.
- Offer a desktop CLI mode that starts and locally controls a terminal also visible on the phone.
- Disconnecting the phone must not stop the terminal; reconnect replays bounded output with explicit reset on gaps.
- Advertise terminal capability; older agents remain usable.

## Acceptance
- Node typecheck/tests, Flutter analyze/tests pass, including real PTY smoke and Dart-to-Node protocol coverage.
- Terminal mode requires no Claude login and no AI API consumption.
- Document startup, tool usage, pairing and security limits accurately.

## Boundaries
Existing arbitrary OS terminals cannot be retroactively attached: start through CloudTerminal. Process persistence across agent restart, E2EE, background push, public deployment and store distribution are outside this continuation. Root selection constrains initial working directories, not shell execution privileges.

## Authorized follow-up
See [desktop-integration.md](desktop-integration.md) for the 2026-10-03 requested easy deployment and Codex Desktop sidebar/control scope. Previous completion applies only to the terminal baseline; this follow-up remains in progress.
