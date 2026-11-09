# Backend Directory Structure

> **Repo split (2026-11-09).** The public relay server — its account, database and OAuth stack, the container image, the Compose/Caddy deployment files and the image-publishing CI — now lives in the separate `cloudterminal-relay-server` repository. This repository keeps only the PC agent plus a 5-file copy of the relay core (`server/src/relay/relay.ts` and `server/src/shared/{relay-protocol,protocol-account,crypto,log}.ts`) so the agent can serve the LAN entry in-process. Never edit those copies here: change them in `cloudterminal-relay-server` first, then run `cd server && npm run sync-relay -- <path-to-cloudterminal-relay-server>`; `server/test/relay-core-sync.test.ts` fails when a copy and `server/relay-core.json` disagree.

Node >=23.6 runs TypeScript directly. tsc only checks types.

```text
server/
  src/shared/       protocol.ts (wire contract), crypto.ts, log.ts
  src/relay/        relay.ts (createRelay), main.ts (entrypoint)
  src/agent/
    core.ts         dispatch, subscriptions, path checks, session registry
    session.ts      Claude session, structural SDK types, ManagedSession
    normalize.ts    defensive SDK-to-event conversion
    queue.ts        async prompt queue
    terminal-session.ts  PTY lifecycle, input, bounded output replay
    pty.ts          native node-pty adapter and injectable structural types
    local-terminal.ts    desktop stdin/stdout attachment
    link.ts         outbound relay socket, pairing, reconnect
    sdk.ts          Claude SDK adapter
    config.ts       persistent agent identity and connection preferences
    setup.ts        first-run setup, URL validation, masked terminal input
    main.ts         CLI composition
  test/             node:test suites, fake-query.ts and helpers.ts
  scripts/          real-Claude e2e.ts and scripted demo-agent.ts
  Dockerfile        minimal relay image; build context is server/
  .dockerignore     allowlisted relay build inputs
  deploy/relay/     locked ws-only package manifest
  deploy/Caddyfile  TLS reverse proxy configuration
  compose.yml       standalone LAN/VPN relay
  compose.tls.yml   standalone Caddy/TLS relay
  README.md         upload-one-directory deployment guide
```

## Rules

Imports use `.ts` and import type; enums/parameter properties cannot be used with erasableSyntaxOnly. Shared modules do not depend on relay/agent.

Only sdk.ts imports the Claude SDK. Native PTY binding imports stay in pty.ts; session tests inject QueryFn/PtyFactory rather than loading an authenticated SDK or native process. Terminal and Claude sessions share lifecycle/subscription plumbing without pretending terminal output is an assistant response.

Client-supplied cwd/listing paths go through AgentCore.checkPath. This is directory selection confinement, not OS process sandboxing. User-facing errors are generally Chinese; operational log messages are English.
