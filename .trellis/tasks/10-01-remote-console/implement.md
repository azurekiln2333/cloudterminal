# Implementation plan

Commit after each step.

1. Server package skeleton: `server/` TypeScript (Node 24 type stripping,
   `tsc --noEmit` for checking), `node --test`.
2. Relay (`server/src/relay/`): auth, routing, presence, rate limit, heartbeat
   + tests.
3. Agent core (`server/src/agent/`): event normalizer, `Session` wrapper
   around SDK `query()` with injectable query fn, `SessionManager`, protocol
   handler + tests with a fake query.
4. Agent CLI: config/pairing (`~/.cloudterminal/agent.json`), relay
   connection with reconnect, `--local-relay`, `--root`, `--allow-bypass`.
5. E2E smoke script: relay + agent + scripted ws client (fake query in CI
   mode; optional real Claude run).
6. App foundation: theme, protocol models, transport, `RemoteController`
   (reconnect, resubscribe, state) + unit tests.
7. App UI: pair screen, home, new-session sheet, session screen, event tiles,
   permission card, composer + widget tests.
8. Docs: README (deploy relay, run agent, pair phone), spec updates.

Validation: `cd server && npm run check && npm test`; `flutter analyze`;
`flutter test`.
