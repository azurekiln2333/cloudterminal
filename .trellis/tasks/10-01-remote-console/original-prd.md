# Remote Claude Code console

## Problem

Claude Code runs on the developer's PC. When away from the desk with only a
phone, remote desktop is too clumsy to follow progress, answer permission
prompts, or type follow-up instructions.

## Goal

A phone app (Flutter, Material 3, UI language shared with `D:\MyNewProjects\terminax`)
that connects to the PC over the internet and lets the user:

1. See the live progress stream of a Claude Code session (assistant text,
   tool calls, tool results, errors, final result / cost).
2. Type a prompt or follow-up message from the phone.
3. Approve or deny permission requests (tool use) from the phone, including
   answering AskUserQuestion-style questions.
4. Start new sessions in a chosen working directory, interrupt a running
   turn, switch permission mode.
5. Reconnect after network loss without losing events (replay from sequence).

## Components

- **Agent** (runs on the PC, Node.js): drives Claude Code through the official
  Claude Agent SDK and exposes sessions over a WebSocket protocol.
- **Relay** (runs on a public server, Node.js): forwards messages between the
  agent (dials out, so no port forwarding on the PC) and phone clients.
- **App** (Flutter): pairing, session list, live session view, composer,
  permission cards.

## Constraints

- No inbound port on the PC is required (agent dials out to the relay).
- Relay must not accept an arbitrary client for an agent: clients present a
  pairing secret, compared in constant time. Agents registering with the relay
  present a relay key when one is configured.
- Transport must be TLS (`wss://`) in any internet deployment; plain `ws://`
  only for LAN / localhost testing.
- Git commit after every step.

## Acceptance criteria

- Relay and agent unit tests pass (`npm test` in `server/`), `tsc --noEmit` clean.
- End-to-end smoke test: relay + agent + scripted client can create a session,
  receive streamed events, receive a permission request, answer it, and see the
  tool result.
- `flutter analyze` clean and widget tests pass.

## Out of scope (v1)

- End-to-end encryption between phone and agent (relay sees plaintext over TLS).
- Attaching to an already-running interactive `claude` terminal session.
- Push notifications when the app is backgrounded.
