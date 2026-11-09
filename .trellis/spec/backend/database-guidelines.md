# Persistence Guidelines

> **Repo split (2026-11-09).** The public relay server — its account, database and OAuth stack, the container image, the Compose/Caddy deployment files and the image-publishing CI — now lives in the separate `cloudterminal-relay-server` repository; the MySQL schema, migrations and account tables described below moved with it. This repository keeps only the PC agent plus a 5-file copy of the relay core (`server/src/relay/relay.ts` and `server/src/shared/{relay-protocol,protocol-account,crypto,log}.ts`) so the agent can serve the LAN entry in-process. Never edit those copies here: change them in `cloudterminal-relay-server` first, then run `cd server && npm run sync-relay -- <path-to-cloudterminal-relay-server>`; `server/test/relay-core-sync.test.ts` fails when a copy and `server/relay-core.json` disagree.

There is no application database, ORM or migration system. `server/src/relay/relay.ts` stores registrations, clients, pairing and throttling in memory. `server/src/agent/core.ts` keeps live sessions/subscriptions in memory. Claude history is loaded through `HistoryLoader` and `server/src/agent/sdk.ts`, not a relay database.

## Scope / Trigger

Changes to identity persistence, reset or config location. Source: `server/src/agent/config.ts`.

## Signatures

`loadConfig(file = configPath(), opts: { reset?: boolean } = {}): Promise<AgentConfig>` and `saveConfig(config: AgentConfig, file = configPath()): Promise<void>`.

## Contract

`CLOUDTERMINAL_HOME` overrides `~/.cloudterminal`; filename is `agent.json`. Fields: `agentId`, `secret`, optional `relayUrl`, `relayKey`, `connectionMode: local | remote`, `roots`, `defaultCwd`, `terminal`, `localPort`. Missing identity or reset generates a new identity while retaining connection preferences. Save writes formatted JSON with a newline to a unique `0600` temporary file, renames it into place, cleans up the temporary file, then applies best-effort chmod. Existing configuration is replaced only after the complete write.

## Validation & Error Matrix

| Condition | Behavior |
| --- | --- |
| ENOENT | Generate and persist identity |
| Complete existing config | Preserve identity |
| reset true | Rotate identity |
| Invalid JSON / other read failure | Throw contextual error |
| Invalid field type, empty roots or port outside 1–65535 | Reject configuration |

Parsing validates known field types and startup preferences. Unknown fields are preserved for compatibility; directory existence and relay URL validation happen at their respective runtime boundaries.

## Good / Base / Bad Cases

Good: reconnect reuses credentials. Base: missing file creates credentials. Bad: corrupt JSON must not silently replace identity.

## Tests Required

When changing persistence, use temporary directories and assert identity reuse, reset, location override and malformed-file failure. Never test against a real user's config.

## Wrong vs Correct

Wrong: regenerate the secret on every reconnect. Correct: load persisted config and pass its identity to `RelayLink`.

Relay registrations and live sessions are not durable. The app marks missing sessions gone after restart; SDK history resume is a separate operation. App storage is documented in the frontend state guidelines.
