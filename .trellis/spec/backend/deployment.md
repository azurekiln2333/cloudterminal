# Desktop setup and relay deployment

> **Repo split (2026-11-09).** The public relay server — its account, database and OAuth stack, the container image, the Compose/Caddy deployment files and the image-publishing CI — now lives in the separate `cloudterminal-relay-server` repository; everything below that describes the relay container, `server/Dockerfile`, the Compose files, `server/deploy/` or the image CI now applies to that repository. This repository keeps only the PC agent plus a 5-file copy of the relay core (`server/src/relay/relay.ts` and `server/src/shared/{relay-protocol,protocol-account,crypto,log}.ts`) so the agent can serve the LAN entry in-process. Never edit those copies here: change them in `cloudterminal-relay-server` first, then run `cd server && npm run sync-relay -- <path-to-cloudterminal-relay-server>`; `server/test/relay-core-sync.test.ts` fails when a copy and `server/relay-core.json` disagree.

## 1. Scope / Trigger

Connection preference, launcher, secret persistence, or Compose changes. The desktop owns PTY/SDK/Codex processes; the deployment image contains only the relay. Source files: `server/src/agent/config.ts`, `setup.ts`, `main.ts`, `server/src/relay/key.ts`, `server/Dockerfile`, and both Compose files in `server/`. The server directory is self-contained: build inputs and Caddy configuration must not reference its parent.

## 2. Signatures

- Desktop: `start.cmd` / `sh start.sh`; `--setup` reruns the wizard.
- `--terminal` / `--no-terminal` persist the local attachment preference.
- `setupConfig(current, prompt): Promise<AgentConfig>` returns updated preferences without rotating pairing identity.
- `registrationKey(env = process.env): Promise<string | undefined>` resolves a relay registration key.
- LAN, from `server/`: `docker compose pull` then `docker compose up -d`.
- TLS: `docker compose -f compose.tls.yml pull` then the same entry's `up -d`.
- Local builds require explicit `-f compose.build.yml` in addition to the selected entry.
- Explicit secret retrieval: `docker compose exec relay node src/relay/show-key.ts` (add the TLS file option for that entry).

## 3. Contracts

CLI connection settings take precedence over `CLOUDTERMINAL_RELAY` / `CLOUDTERMINAL_RELAY_KEY`, then saved configuration. Environment overrides do not persist secrets. A saved key must never accompany a different relay URL unless explicitly supplied for that connection. A CLI key supplied with a temporary environment URL applies to that run without overwriting another saved target's key. Local relay mode ignores unrelated remote overrides. Startup options and identity live together under `CLOUDTERMINAL_HOME` or `~/.cloudterminal`.

`RELAY_KEY` overrides `RELAY_KEY_FILE`. The Dockerfile sets `RELAY_KEY_FILE=/data/relay-key`; a named volume retains this file. First generation publishes a fully written `0600` temporary file with an exclusive hard link, preserving a concurrent winner. Routine logs omit the secret; `show-key.ts` is the explicit disclosure command. The registration key is for the desktop, while phones exchange a separate short pairing code.

The image uses Node 24 and locked `ws` / `mysql2` runtime dependencies from
`server/deploy/relay/`. It copies the shared, relay, db and oauth source trees;
the import-graph test must catch any runtime dependency outside those trees.
Desktop Agent / PTY / SDK dependencies stay outside the relay image.
The process runs as the Node user, with `/data` writable. `/healthz` is the health
check. The LAN entry publishes `RELAY_PORT` (default 8787); the standalone TLS
entry publishes only TCP 80/443 through Caddy and sets `RELAY_TRUST_PROXY=1`.
`RELAY_DOMAIN` is required for TLS. Do not combine the entries: stop the old
deployment without deleting volumes before switching.

Default Compose entries have an `image`, with configurable `RELAY_IMAGE`, and
no build section. Server deployment needs only these entries, configuration and
the TLS Caddyfile. Source builds use the explicit `compose.build.yml` override.
GitHub `.github/workflows/image.yml` and CNB `.cnb.yml` build/publish images;
pull requests never publish, and prerelease tags never move `latest`. Repository
and registry names derive from the actual CI environment or explicit overrides.
An example image path is not evidence of publication: distinguish local build /
runtime verification from an actual registry push and server pull.

Both Compose entries set `name: cloudterminal`, retaining the old root directory's default project/volume identity when run inside `server/`. Deployments previously started with a custom `-p` or `COMPOSE_PROJECT_NAME` must keep that name. Never delete volumes to migrate directory layout. `.env.example` contains sample settings; the actual `.env` stays ignored. Source upload archives must contain all relative build inputs and exclude credentials, local dependencies and the user-owned root `server.zip`.

## 4. Validation & Error Matrix

| Condition | Expected behavior |
| --- | --- |
| Existing complete configuration | Reuse settings and pairing identity |
| `--setup` cancelled or invalid URL/port/directory | Show error without partially saving wizard preferences |
| Shared terminal requested without TTY | Explain `--no-terminal` and exit |
| Different environment relay target without explicit key | Do not forward saved key |
| Relay key file empty/unreadable | Fail instead of falling back to unauthenticated registration |
| Explicit `RELAY_KEY` or `RELAY_KEY_FILE` is empty | Reject the invalid setting |
| Invalid relay `PORT` | Fail before creating a key file |
| Docker absent on developer host | Report runtime verification unavailable; do not claim image success |
| Only `server/` uploaded | Every Docker COPY and Compose bind source resolves within that directory |

## 5. Good / Base / Bad Cases

Good: subsequent launches and container restarts reuse configuration and key. Base: first launch prompts once and first relay start creates the persistent key. Bad: switching an address leaks the previous key, or replacing the TLS entry with an overlay keeps port 8787 public.

## 6. Tests Required

Use temporary configuration directories and ephemeral local ports. Verify identity reuse/reset, validation, command/env precedence, wizard cancellation and hidden input, registration rejection without the correct key, concurrent key creation, and repeated startup. For packaging, verify Compose paths, Docker COPY sources, runtime imports, unchanged project/volume names and archive entries. Runtime container evidence must come from an actual Docker host; static checks cannot establish image startup or volume permissions.

## 7. Wrong vs Correct

Wrong: save `process.env.CLOUDTERMINAL_RELAY_KEY` into the user's settings or log it during ordinary startup. Correct: resolve it only for the active connection and reveal a server key only through the deliberate `show-key.ts` command.
