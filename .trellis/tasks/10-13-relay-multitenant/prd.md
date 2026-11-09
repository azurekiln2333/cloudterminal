# Relay multi-tenant identity: many users, many computers

## Goal

Give the relay a real tenant model backed by the existing OAuth2 gateway
(`D:\MyNewWebProjects\azurekiln-oauth2`, MySQL). Accounts own many computers,
one computer can be bound by many accounts, and bindings survive relay
restarts. Server-side only (`server/`); the Flutter apps are owned by other
agents and must not be broken.

## Requirements

### Identity and login

- R1. Accounts come from the external OAuth2 / OIDC gateway. The relay stores
  no user table, no password, no email. The relay's local account row is a
  cache keyed by the gateway `sub` claim.
- R2. Support the standard authorization-code + PKCE flow (flow **A**): the app
  opens a system browser, the gateway redirects back to the app with a code,
  and the app presents the code to the relay, which exchanges it at the gateway
  token endpoint.
- R3. Support the device authorization flow (flow **B**, RFC 8628) for clients
  that cannot host a browser or a custom URL scheme: the client asks the relay
  for a `user_code` + `verification_uri`, the user approves in a browser, the
  client polls the relay until it receives relay credentials.
- R4. When the gateway does not advertise the device-authorization endpoint,
  the relay reports that clearly; flow A must keep working.
- R5. The relay validates gateway tokens two ways, both configurable:
  - R5.1. Remote introspection at the gateway `/oauth2/introspect`.
  - R5.2. Local RS256 verification against the gateway JWKS
    (`/.well-known/jwks.json`), including issuer and audience checks.
  JWKS verification is preferred when configured; introspection is the fallback.

### Binding model (many-to-many)

- R6. `account → many devices`: one account may bind an arbitrary number of
  computers.
- R7. `device → many accounts`: one computer may be bound by an arbitrary
  number of accounts, and every bound account may drive it concurrently.
- R8. Binding is persisted in MySQL and survives relay restarts. Relay restarts
  must not require re-pairing.
- R9. Each binding records who created it, when, an optional display label, and
  a status (`active` / `revoked`) so a single binding can be revoked without
  touching the others.
- R10. An account may list its devices; a device owner may list the accounts
  bound to it; either side may revoke a binding.

### Device authentication

- R11. A computer authenticates as itself with a device credential
  (`deviceId` + device secret), independent of any account. This is what keeps
  the current agent flow working.
- R12. Binding an account to a computer requires proof from **both** sides:
  the account holder is authenticated by the gateway, and the computer consents
  through a short-lived pairing code shown by the desktop launcher (reuse of
  the existing `pair_code` mechanism).
- R13. A client authenticated by an account may connect to any device bound to
  that account without knowing the device secret.

### Persistence

- R14. MySQL 8 / InnoDB is the only database. SQLite, JSON files and in-memory
  long-term state are not acceptable stores for accounts, devices, bindings or
  tokens. The relay's memory maps remain a live-session cache only.
- R15. Schema is created by explicit, versioned, idempotent migrations run
  before the relay serves traffic — never auto-created by a request path.
- R16. The database is reached through a small pool with a configurable
  connection limit, connection timeouts and TLS support (`DB_TLS`,
  `DB_TLS_CA_FILE`), following the gateway's conventions.
- R17. Credentials (device secrets, relay-issued account/device tokens) are
  stored as salted hashes only; no plaintext secret is persisted or logged.
- R18. The relay must start and serve the legacy protocol even when the
  database is unreachable, but account features report a degraded state instead
  of failing silently.

### Configuration

- R19. All new settings come from environment variables with the existing
  `RELAY_*` / new `DB_*`, `OAUTH_*` prefixes. Query strings, key names and codes
  use lower_snake_case.
- R20. The existing global `RELAY_KEY` registration key keeps working exactly
  as today; it is not replaced.

### Backward compatibility

- R21. An agent or client that sends the current `hello` frame (no new fields)
  behaves exactly as before.
- R22. The existing one-time `pair_code` → `paired` flow keeps working and keeps
  handing out the device secret to unauthenticated phones.
- R23. New protocol frames are additive and optional. `PROTOCOL_VERSION` is not
  bumped; the relay negotiates by the presence of new fields.
- R24. Dart mirrors of the protocol (iOS/Android and herdr) are **not** edited
  in this task. The protocol file must document the new frames for the other
  agents, in the existing mirrored comment style.

## Constraints

- Scope is `server/` only. No Dart, Kotlin, Swift or Flutter changes.
- No self-built user table; the gateway stays the identity source of truth.
- No SQLite, no ORM required (a thin SQL layer with prepared statements is
  fine and preferred over a heavy dependency).
- The relay must keep running behind the existing Caddy / Docker Compose
  deployment, and the MySQL settings must be documentable in `server/README.md`
  and `.env.example`.
- Existing tests in `server/test/` must keep passing unchanged.

## Acceptance Criteria

- [ ] AC1. Two accounts each binding two devices cannot see or reach each
      other's devices; cross-account client auth is rejected.
- [ ] AC2. Two accounts bound to the same device can both connect and both
      receive agent messages concurrently.
- [ ] AC3. After the relay process is restarted against the same MySQL, an
      account token still resolves to its bindings without re-pairing.
- [ ] AC4. Revoking one binding leaves the other bindings on that device
      working.
- [ ] AC5. Flow A completes end-to-end against a stub gateway: authorize →
      code → relay exchange → relay-issued credentials → device list.
- [ ] AC6. Flow B completes end-to-end against a stub gateway: `user_code` →
      poll `authorization_pending` → approval → relay-issued credentials.
- [ ] AC7. Both introspection and JWKS validation reject expired tokens, wrong
      issuer, wrong audience, and unknown signing keys.
- [ ] AC8. A legacy agent and a legacy client (protocol version 1, no new
      fields) pass the full existing `server/test/` relay suite unchanged.
- [ ] AC9. Bindings, devices and tokens are present in MySQL after the relay
      restarts; no plaintext secret is readable in the tables or the logs.
- [ ] AC10. With the database unreachable, the relay still starts and legacy
      pairing/driving works.
- [ ] AC11. `server/README.md` and `server/.env.example` document every new
      setting, the migration command, and the OAuth client registration that
      the gateway operator must perform.

## Out of scope

- Any Dart/Flutter UI for login or the device list.
- Changes inside `azurekiln-oauth2`.
- End-to-end encryption of relayed payloads.
- Billing, quotas, or per-account rate limits beyond the existing per-IP
  throttling.

## Notes

- Gateway endpoints available today: `/oauth2/authorize`, `/oauth2/token`,
  `/oauth2/userinfo`, `/oauth2/introspect`, `/oauth2/revoke`,
  `/.well-known/openid-configuration`, `/.well-known/jwks.json`.
- The gateway operator must register a relay client, e.g.
  `client_id=cloudterminal-relay`, `redirect_uri=cloudterminal://oauth/callback`,
  scope `openid profile`.
