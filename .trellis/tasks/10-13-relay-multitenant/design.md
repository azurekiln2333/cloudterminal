# Design: relay multi-tenant identity

Parent PRD: `prd.md`. Scope: `server/` only.

## 1. Context

Today the relay (`server/src/relay/relay.ts`) is a stateless in-memory switch:

- `agents: Map<agentId, AgentEntry>` — one socket per computer, `clients: Map<clientId, ws>`.
- Identity is a computer-generated `agentId` + `secret`; the phone receives that
  same secret through a one-time `pair_code`.
- Nothing survives a restart; there is no account concept.

We add an account layer sourced from the external OAuth2/OIDC gateway
(`azurekiln-oauth2`, MySQL) without disturbing that switch.

## 2. Boundaries

```
browser --(A: PKCE redirect)--> gateway
                                  |
phone/desktop --(code/token)---> relay  <--(device auth)--- computer
                                  |  \
                                  |   `-- HTTPS --> gateway (introspect / JWKS / token)
                                  `-- MySQL (accounts, devices, bindings, tokens)
```

The relay becomes a **resource server + binding registry**. It never stores
passwords and never renders a login page.

### New modules (all under `server/src/`)

| Path | Responsibility |
| --- | --- |
| `db/pool.ts` | MySQL pool from env, TLS options, `ping()`, graceful close. |
| `db/migrate.ts` | Versioned idempotent DDL; CLI + programmatic entry. |
| `db/schema.sql.ts` | Inline SQL statements for the migrations. |
| `db/accounts.ts` | Account upsert from gateway claims; lookup. |
| `db/devices.ts` | Device upsert (deviceId + secret hash), label, status. |
| `db/bindings.ts` | create / list / revoke bindings (the M:N table ops). |
| `db/tokens.ts` | Issue/verify/revoke relay tokens (hashed at rest). |
| `oauth/config.ts` | `OAUTH_*` env parsing and validation. |
| `oauth/discovery.ts` | Fetch and cache `/.well-known/openid-configuration`. |
| `oauth/jwks.ts` | Fetch + cache JWKS, RS256 verify with `kid` lookup. |
| `oauth/introspect.ts` | Remote introspection fallback. |
| `oauth/flows.ts` | Flow A (code+PKCE) and Flow B (device code) against the gateway. |
| `relay/api.ts` | HTTP routes for auth, device list, binding revoke. |
| `relay/tenancy.ts` | Bridges DB bindings into relay routing decisions. |

Existing files edited: `relay/relay.ts` (routing to multiple accounts),
`relay/main.ts` (wire pool/migrations), `shared/protocol.ts` (optional frames),
`.env.example`, `README.md`, `Dockerfile`, `compose*.yml`.

## 3. Data model (MySQL 8 / InnoDB, utf8mb4)

No user table: `accounts` is a cache of gateway subjects. No email, no password.

```sql
-- v1
create table ct_accounts (
  account_id     varchar(191) not null,      -- gateway `sub`, opaque
  issuer         varchar(255) not null,      -- protects against sub collisions
  display_name   varchar(191) null,
  created_at     timestamp not null default current_timestamp,
  updated_at     timestamp not null default current_timestamp on update current_timestamp,
  primary key (account_id),
  key ct_accounts_issuer (issuer)
) engine=InnoDB default charset=utf8mb4;

create table ct_devices (
  device_id      varchar(128) not null,      -- agentId
  label          varchar(191) null,          -- friendly name, set by agent
  platform       varchar(64)  null,
  secret_hash    char(64) not null,          -- sha256(secret) hex; never the secret
  created_at     timestamp not null default current_timestamp,
  last_seen_at   timestamp null,
  revoked_at     timestamp null,
  primary key (device_id)
) engine=InnoDB default charset=utf8mb4;

-- The many-to-many core.
create table ct_bindings (
  id             bigint unsigned not null auto_increment,
  account_id     varchar(191) not null,
  device_id      varchar(128) not null,
  role           enum('owner','member') not null default 'member',
  label          varchar(191) null,
  status         enum('active','revoked') not null default 'active',
  created_by     varchar(64)  not null,      -- 'pair_code' | 'device_auth' | 'admin'
  created_at     timestamp not null default current_timestamp,
  revoked_at     timestamp null,
  primary key (id),
  unique key ct_bindings_account_device (account_id, device_id),
  key ct_bindings_device (device_id, status),
  constraint ct_bindings_account_fk foreign key (account_id) references ct_accounts(account_id) on delete cascade,
  constraint ct_bindings_device_fk  foreign key (device_id)  references ct_devices(device_id)  on delete cascade
) engine=InnoDB default charset=utf8mb4;

create table ct_tokens (
  token_hash     char(64) not null,          -- sha256(token) hex
  account_id     varchar(191) not null,
  device_id      varchar(128) null,          -- null = account-scoped token
  kind           enum('access','refresh','device') not null,
  expires_at     timestamp not null,
  created_at     timestamp not null default current_timestamp,
  revoked_at     timestamp null,
  primary key (token_hash),
  key ct_tokens_account (account_id, kind),
  key ct_tokens_expiry (expires_at)
) engine=InnoDB default charset=utf8mb4;

create table ct_oauth_states (
  state          varchar(128) not null,      -- PKCE state / device flow id
  kind           enum('pkce','device') not null,
  code_verifier  varchar(128) null,
  device_id      varchar(128) null,          -- which computer initiated
  user_code      varchar(32)  null,
  expires_at     timestamp not null,
  created_at     timestamp not null default current_timestamp,
  primary key (state),
  key ct_oauth_states_expiry (expires_at)
) engine=InnoDB default charset=utf8mb4;
```

Migration rules: a `ct_schema_migrations(version, applied_at)` table, statements
applied in a transaction, DDL only, never in a request path. Re-running is a
no-op. Cleanup of `ct_oauth_states` / `ct_tokens` rows happens on a timer, not
inline with reads.

**Why `issuer` matters**: the gateway's `sub` is only unique within an issuer.
Storing it keeps a future second IdP from colliding with an existing account ID.

## 4. Authentication flows

### 4.1 Flow A — authorization code + PKCE

```
client(app) start:
  POST /api/v1/auth/oauth/start {code_challenge, redirect_uri}
    relay -> stores ct_oauth_states(state, pkce, code_verifier=null)
    relay -> returns {authorizeUrl: <gateway>/oauth2/authorize?response_type=code
                      &client_id=...&redirect_uri=...&scope=openid profile
                      &state=...&code_challenge=...&code_challenge_method=S256}
  app opens authorizeUrl in the system browser
  gateway authenticates + MFA + consent, redirects to cloudterminal://oauth/callback?code=..&state=..
  app: POST /api/v1/auth/oauth/complete {code, state, code_verifier}
    relay validates state (single use, unexpired)
    relay -> POST <gateway>/oauth2/token (authorization_code + code_verifier)
    relay validates the id_token/access_token (JWKS or introspect)
    relay upserts ct_accounts
    relay issues relay access + refresh token (rotate on use)
    relay -> {accountId, displayName, accessToken, refreshToken, expiresAt}
```

The relay holds the OAuth client secret (`OAUTH_CLIENT_SECRET`) and is the only
party that talks to the gateway token endpoint. The app never sees the gateway
secret or the gateway tokens.

### 4.2 Flow B — device authorization (RFC 8628)

```
desktop agent (unauthenticated) -> POST /api/v1/auth/device/start {deviceId, label}
  relay -> POST <gateway>/oauth2/device_authorization (if advertised in discovery)
  relay stores ct_oauth_states(device=user_code .. device_id)  -- binds approval to device
  relay -> {userCode, verificationUri, interval, expiresIn}
desktop prints: "visit <verificationUri> and enter <userCode>"
user completes auth in a browser
desktop polls POST /api/v1/auth/device/poll {deviceId, userCode}
  relay -> gateway token endpoint -> account claims
  -> upsert account, upsert device, create/refresh binding(created_by='device_auth')
  -> relay -> {status:'approved', accessToken, ...}
```

When the gateway does not advertise `device_authorization_endpoint`, the relay
answers `501 device_flow_unsupported` and flow A stays available. Because the
gateway is ours, adding that endpoint is a follow-up on that project, not here.

### 4.3 Token validation

`oauth/verify.ts` picks one strategy per configuration:

1. **JWKS (preferred)** — fetch discovery once, cache JWKS by `kid` with TTL,
   verify RS256 signature, then check `iss` (strict prefix match against the
   discovered issuer), `aud` (must contain `OAUTH_AUDIENCE`), `exp`, `nbf`,
   `iat` with a small clock skew. No network call per request.
2. **Introspection (fallback)** — `POST /oauth2/introspect` with client
   credentials; require `active: true` and the same issuer/audience checks.
   Responses are cached for the token's remaining lifetime, bounded.

Both paths return a normalized `{sub, issuer, name?}`. Failure is a
`401 unauthorized` with a machine-readable code; the raw token is never logged.

### 4.4 Relay-issued tokens

Relay tokens are the app's long-lived credential so it does not need the
gateway on every reconnect. Format: `ct_<32 bytes base64url>`, stored as
`sha256` in `ct_tokens`. Access tokens are short (default 1 h), refresh tokens
long (default 30 d) and rotate on use — a rotated refresh token revokes its
predecessor. Revocation is immediate (the row's `revoked_at` is set), which is
the property the gateway cannot give us cheaply for WebSocket reconnects.

## 5. Relay routing changes

`relay.ts` keeps its shape; the new capability is that **one device may serve
clients authenticated by different accounts**.

- `AgentEntry` gains `secretHash` (already), plus a lazily refreshed
  `boundAccounts: Set<string>` from `ct_bindings` when the DB is available.
- `onClient` accepts one of:
  - legacy: `agentId` + `secret` (unchanged path), or
  - account: `agentId` + relay access token, where the relay resolves the token
    to `accountId` and checks `ct_bindings(accountId, deviceId, status='active')`.
- Delivery already supports `to: clientId` fan-out; a bound client is just an
  entry in `agent.clients`. Two accounts bound to one device therefore get
  concurrent sessions with no routing change beyond authorization.
- Fan-out (`msg` without `to`) continues to broadcast to every client of that
  device; per-account isolation is not attempted at the message level, because
  the clients of one device are deliberately sharing that device.

The DB is consulted only on connect, on binding change, and on a slow refresh
interval — never on the hot message path.

## 6. Protocol additions (additive, optional)

Documented in `shared/protocol.ts` next to the existing frames. No version bump.

```ts
// hello (agent) may additionally carry: relayToken?: string
// hello (client) may carry: relayToken?: string instead of secret
// new frames:
| { t: 'devices'; devices: { deviceId: string; label?: string; online: boolean }[] }
| { t: 'accounts'; deviceId: string; accounts: { accountId: string; label?: string }[] }
| { t: 'bind_revoked'; deviceId: string; accountId: string }
```

Rule: an agent or client that omits every new field must observe byte-identical
behavior to today. The relay decides by field presence, not by a version gate.

## 7. Configuration

New env (documented in `.env.example` and `README.md`):

```dotenv
# MySQL
DB_HOST=127.0.0.1
DB_PORT=3306
DB_USER=cloudterminal
DB_PASSWORD=
DB_NAME=cloudterminal
DB_CONNECTION_LIMIT=10
DB_CONNECT_TIMEOUT_MS=10000
DB_TLS=false
DB_TLS_CA_FILE=

# OAuth2 / OIDC gateway
OAUTH_ISSUER=https://sso.example.com
OAUTH_CLIENT_ID=cloudterminal-relay
OAUTH_CLIENT_SECRET=
OAUTH_AUDIENCE=cloudterminal-relay
OAUTH_REDIRECT_URI=cloudterminal://oauth/callback
OAUTH_SCOPES=openid profile
OAUTH_VERIFY=jwks            # jwks | introspect
OAUTH_JWKS_TTL_MS=3600000
OAUTH_INTROSPECT_CACHE_MS=60000

# Relay-issued tokens
RELAY_ACCESS_TTL_MS=3600000
RELAY_REFRESH_TTL_MS=2592000000
```

Invalid or partially configured OAuth settings put the relay into **degraded
mode**: it logs one actionable warning, disables `/api/v1/auth/*`, and serves
the legacy protocol normally. This satisfies PRD R18.

## 8. Deployment

- `Dockerfile`: the relay image already runs Node with a locked `ws` dependency;
  add `mysql2` to the relay's dependency set (`server/package.json`).
- `compose.yml` / `compose.tls.yml`: pass the new env through, and document an
  external MySQL (the DB is not containerised here, matching the gateway's
  "connect to MySQL" model).
- Migrations run before traffic: an explicit `docker compose run --rm relay
  node src/db/migrate.ts` documented in the README, plus a guarded automatic
  check at startup that **fails loudly** only when `RELAY_DB_AUTO_MIGRATE=1`.

## 9. Security notes

- The relay never logs tokens, secrets, authorization codes or `code_verifier`.
- Pairing codes stay single-use and short-lived; binding via `pair_code` also
  creates a `ct_bindings` row with `created_by='pair_code'`.
- Binding by code and binding by account are separate: knowing a pairing code
  still only yields the device secret, not account access, and vice versa.
- Per-IP throttling is unchanged and reused for the new auth endpoints.
- `OAUTH_CLIENT_SECRET` and `DB_PASSWORD` are the only new secrets; both stay
  in the environment, never in the repository.
- Because the gateway is a separate host, discovery/JWKS/introspection calls
  must have timeouts and must never block a websocket upgrade.

## 10. Tradeoffs

| Decision | Alternative | Why this |
| --- | --- | --- |
| Relay-issued tokens | Use gateway tokens on every WS connect | WS reconnects are frequent; no network hop, instant revocation, no gateway load spike |
| `accounts` cache table | Pure in-memory cache | Device list and bindings must survive restart (PRD R8) |
| MySQL + thin SQL | ORM | Nothing in the repo uses an ORM; prepared statements keep the dependency surface small |
| Binding is M:N with status | Soft delete only | Lets one binding be revoked without affecting the device's other accounts (PRD R9, AC4) |
| Introspection as fallback | JWKS only | Some deployments run the gateway behind a private network without exposing JWKS |

## 11. Rollback

Every change is additive and gated by configuration. Setting no `DB_*`/`OAUTH_*`
variables restores today's behavior exactly. The migration only **creates**
`ct_*` tables; dropping them is a documented manual step and is never part of a
down-migration, so a rollback cannot destroy device bindings silently.

## 12. Open questions

1. Does the gateway already expose `device_authorization_endpoint`? If not,
   flow B is implemented and tested against a stub, and the endpoint addition
   is a follow-up on that project.
2. Is one relay instance expected, or several behind a load balancer? Bindings
   live in MySQL so multi-instance is safe; websocket affinity is the operator's
   concern and is called out in the README.
