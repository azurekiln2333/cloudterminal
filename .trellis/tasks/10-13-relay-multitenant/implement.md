# Implement: relay multi-tenant identity

Parent PRD: `prd.md`; design: `design.md`. Scope: `server/` only.
Every step is independently verifiable; run the listed command before moving on.

## Dependency

- `mysql2` added to `server/package.json` (and the relay-only lock used by the
  Docker image, `server/deploy/relay/package.json`, if that is the build input).
- No test-only database server is assumed. DB-touching tests must skip with a
  clear message unless `CT_TEST_MYSQL_URL` (or the `DB_*` vars) is set, so the
  existing suite still passes on a machine without MySQL.

## Ordering

Steps 1–3 are pure additions and safe to land first. Step 4 changes relay
routing and must not start until step 3's tests are green. Steps 5–6 are flows
and routes. Step 7 is compatibility proof. Step 8 is docs and deploy.

---

## Step 1 — Config and pool

- [ ] `server/src/oauth/config.ts`: parse and validate `OAUTH_*`, return a
      `disabled | degraded | ready` state with an actionable message.
- [ ] `server/src/db/pool.ts`: build a `mysql2` pool from `DB_*`, honour
      `DB_TLS` / `DB_TLS_CA_FILE`, expose `ping()` and `close()`. Never connect
      at import time.
- [ ] `server/src/db/config.ts`: same shape for `DB_*`.
- [ ] Unit tests: partial config → degraded; bad ports/timeouts → throw;
      `DB_TLS=true` without CA still builds (system CA); no network I/O.

Verify: `cd server && npx tsx --test test/oauth-config.test.ts test/db-config.test.ts`

## Step 2 — Migrations

- [ ] `server/src/db/schema.sql.ts`: the five `ct_*` tables from design §3,
      each statement idempotent (`create table if not exists`).
- [ ] `server/src/db/migrate.ts`: `ct_schema_migrations` bookkeeping, ordered
      versions, applied inside a transaction, callable as a CLI
      (`node src/db/migrate.ts`) and as `runMigrations(pool)`.
- [ ] Startup wiring in `relay/main.ts`: run migrations only when
      `RELAY_DB_AUTO_MIGRATE=1`; otherwise log the exact command to run.
- [ ] Tests: re-running migrations twice is a no-op; the migrations table
      records versions; a deliberately broken statement rolls back.

Verify: `npx tsx --test test/db-migrate.test.ts` (skips without MySQL)

## Step 3 — Data access layer

- [ ] `db/accounts.ts`: `upsertAccount({accountId, issuer, displayName})`,
      `getAccount(id)`.
- [ ] `db/devices.ts`: `upsertDevice({deviceId, label, platform, secretHash})`,
      `touchDevice(deviceId)`, `getDevice(id)`, `setRevoked(...)`.
- [ ] `db/bindings.ts`: `createBinding({accountId, deviceId, role, label,
      createdBy})` (idempotent on the unique key, reactivating a revoked row),
      `listDevicesForAccount(accountId)`, `listAccountsForDevice(deviceId)`,
      `revokeBinding(accountId, deviceId)`, `isBound(accountId, deviceId)`.
- [ ] `db/tokens.ts`: `issueToken({accountId, deviceId, kind, ttlMs})` returning
      the plaintext **once**, `verifyToken(token)` → `{accountId, deviceId, kind}`
      or null, `revokeToken`, `rotateRefresh(oldToken)` (revoke old, issue new),
      `purgeExpired()`.
- [ ] All statements use prepared placeholders; no string interpolation of
      values into SQL.
- [ ] Tests (skipped without MySQL): M:N insert, idempotent re-bind, revoke one
      binding leaves the other, token round-trip, rotated refresh token cannot
      be reused, expired token rejected, `sha256` stored instead of plaintext.

Verify: `npx tsx --test test/db-bindings.test.ts test/db-tokens.test.ts`

## Step 4 — Relay routing authorization

- [ ] `relay/relay.ts`: accept `relayToken` on client `hello`; resolve it,
      check `isBound(accountId, deviceId)`, then join `agent.clients` exactly
      like the legacy path.
- [ ] Cache binding lookups per (accountId, deviceId) with a short TTL; refresh
      on `bind_revoked`.
- [ ] Keep the legacy `agentId` + `secret` path byte-identical.
- [ ] Support an account client with **no** `agentId` in `hello` by expanding
      `devices` first (the client picks a device, then sends a device-scoped
      `hello`) — this is additive; if the frame is absent, behavior is unchanged.
- [ ] Tests: two accounts on one device both connect and both receive `msg`
      without `to`; account A cannot connect to account B's device; revoked
      binding drops the connection with a typed error.

Verify: `npx tsx --test test/relay-tenancy.test.ts`

## Step 5 — OAuth verification and flows

- [ ] `oauth/discovery.ts`: fetch `/.well-known/openid-configuration` with a
      timeout, cache, expose endpoints, tolerate absence.
- [ ] `oauth/jwks.ts`: fetch JWKS, cache by `kid`, verify RS256, check
      `iss`/`aud`/`exp`/`nbf` with clock skew.
- [ ] `oauth/introspect.ts`: client-credentials introspection with bounded
      caching.
- [ ] `oauth/verify.ts`: strategy selection + normalized `{sub, issuer, name}`.
- [ ] `oauth/flows.ts`: flow A (`start` builds the PKCE URL, `complete`
      exchanges the code and validates the result) and flow B
      (`device/start`, `device/poll` incl. `authorization_pending`,
      `slow_down`, `expired_token`, `access_denied`).
- [ ] Tests against a local stub gateway (an `http` server in the test file,
      not a real network dependency): happy path, expired token, wrong issuer,
      wrong audience, unknown `kid`, introspection `active:false`, device flow
      pending→approved, and `device_flow_unsupported` when discovery lacks the
      endpoint.

Verify: `npx tsx --test test/oauth-*.test.ts`

## Step 6 — HTTP API

- [ ] `relay/api.ts`: routes under `/api/v1/`, JSON errors with machine-readable
      codes, per-IP throttling reused from the relay, correct `4xx`/`5xx` split.
      - `POST /api/v1/auth/oauth/start`, `POST /api/v1/auth/oauth/complete`
      - `POST /api/v1/auth/device/start`, `POST /api/v1/auth/device/poll`
      - `POST /api/v1/auth/token/refresh`, `POST /api/v1/auth/logout`
      - `GET  /api/v1/devices`, `POST /api/v1/devices/:id/bindings`
      - `GET  /api/v1/devices/:id/accounts`, `DELETE /api/v1/devices/:id/bindings/:accountId`
- [ ] Attach to the existing HTTP server in `relay/main.ts` (same port as `/ws`
      and `/healthz`); never break the upgrade handler.
- [ ] `/healthz` stays cheap; add `/readyz` that reports DB and OAuth state.
- [ ] Tests: auth required, listing isolation (AC1), binding creation via
      `pair_code` consent, revoke isolation (AC4), degraded mode returns 503
      with an actionable body, `/ws` still upgrades.

Verify: `npx tsx --test test/relay-api.test.ts`

## Step 7 — Compatibility proof

- [ ] Add a test asserting a protocol-version-1 agent and client (no new fields)
      complete the whole legacy flow: register → pair code → client join →
      `msg` both directions → normal close.
- [ ] Run the untouched existing suite.
- [ ] Add a restart test with MySQL: create binding, tear the relay down,
      build a new relay on the same DB, assert the account token still resolves
      and the device list is intact (AC3).

Verify: `cd server && npm run check && npm test`

## Step 8 — Docs and deploy

- [ ] `server/.env.example`: every new variable with a safe default and a
      comment; keep the file copy-paste runnable.
- [ ] `server/README.md`: MySQL requirement, migration command, OAuth client
      registration to perform on the gateway (`client_id`, redirect URI, scope,
      audience), degraded-mode explanation, multi-instance/LB note.
- [ ] `compose.yml` / `compose.tls.yml`: pass the new env, document external
      MySQL; do not add a database container.
- [ ] `server/Dockerfile`: ensure `mysql2` is present in the image's dependency
      install.
- [ ] Note in `TUNNEL.md` (one paragraph) that account login is independent of
      the chosen ingress.

Verify: `npm run check`; build the image if Docker is available on the host.

---

## Validation commands

```powershell
cd D:\MyNewProjects\cloudterminal\server
npm run check
npm test
npx tsx --test test/relay-tenancy.test.ts test/oauth-flows.test.ts
```

DB-backed suites are opt-in:

```powershell
$env:CT_TEST_MYSQL_URL = 'mysql://user:pass@127.0.0.1:3306/cloudterminal_test'
npx tsx --test test/db-*.test.ts
```

## Review gates

1. After step 3: data layer reviewed before any routing change.
2. After step 4: routing reviewed against AC1/AC2/AC4 — this is where a tenancy
   bug would leak one account's device to another.
3. After step 6: full API surface reviewed against the PRD's acceptance list.
4. After step 7: compatibility + restart evidence before docs.

## Rollback points

- Steps 1–3 add modules and tables only; reverting the commit is safe and no
  existing code path changes.
- Step 4 is the first behavioral change; revert it to return to today's routing.
- Unsetting `DB_*` / `OAUTH_*` disables every new feature without a code change.

## Stop conditions

- If the gateway's `sub` is not stable across logins, stop and fix the identity
  assumption before building bindings on it.
- If MySQL is unreachable in the target environment, ship steps 1–3 and 7 only,
  and keep the feature behind configuration until a database is available.
