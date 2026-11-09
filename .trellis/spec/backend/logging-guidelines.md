# Logging Guidelines

`server/src/shared/log.ts` defines Logger.info/warn/error(message, optional Record<string, unknown>). There is no debug level. `consoleLogger(scope)` writes ISO timestamp, level, scope, message and space-separated key=value fields; this is not JSON Lines. Non-string field values are JSON-serialized.

Core, relay and link inject a logger, defaulting to `silentLogger`; entrypoints create scoped console loggers.

```ts
this.log = opts.logger ?? silentLogger;
this.log.warn('request failed', { type: msg.type, message });
```

Sources: `server/src/agent/core.ts`, `server/src/agent/link.ts`, `server/src/relay/relay.ts`.

- Info: session creation, agent/client connection changes.
- Warn: rejected requests/credentials, socket errors, retries, oversized frames.
- Error: relay rejection or conflicting agent identity preventing progress.

Select fields deliberately: logger does not redact. Do not log complete handshake frames, secrets, relay keys or transcript bodies. The relay entrypoint in `cloudterminal-relay-server` (`src/relay/main.ts`) reports relay-key state as required/off, never its value. Deliberate CLI pairing instructions are separate from routine network logs.
