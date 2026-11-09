# Follow-up: easy deployment and Codex Desktop sidebar

## User-authorized scope (2026-10-03)
The user requested simpler desktop relay connection, Docker server deployment, Codex Desktop historical sessions/projects in a sidebar, preserving standard Material 3 styling. Continue existing work without losing the previous terminal functionality or pending commit plan.

## Independent delivery A: connection and deployment
- A root start.cmd launches the PC agent. First launch has interactive connection setup; later launches reuse configuration. --setup reconfigures.
- Persist connection mode, relay URL/key, roots/default cwd, shared terminal preference and local port; preserve pairing identity. Explicit CLI args override stored preferences.
- Compose LAN/VPN entry and separate Compose TLS/Caddy entry. Relay image installs ws only, not Claude SDK or native PTY.
- Relay registration key is generated once into a persistent volume, not logged; explicit show-key command supports initial setup.
- Preserve explicit environment overrides, fail clearly for invalid configuration. Do not expose the raw Codex daemon over the network.
- Packaging clarification (2026-10-03): keep all relay deployment files inside `server/`, so uploading that one directory is sufficient. Move Compose, Docker build inputs, Caddy and instructions together; preserve existing volume identity. Leave the user's root `server.zip` untouched and provide a separately named upload archive.

## Delivery B: desktop projects/history and control
- Prefer the running Codex Desktop app-server via local stdio proxy, never silently start a second app-server against the same history.
- This machine's 0.160.0 exposes project/list, project/read and thread/list (projectId, updated_at, useStateDbOnly), thread/read, thread/resume, turn/start/steer/interrupt. Validate exact schema against installed binary.
- Read real projects and threads; no fake fallback. Availability and errors shown clearly if Desktop daemon/proxy unavailable.
- Mobile Material 3 sidebar: narrow screen navigation drawer, wide screen persistent side panel, project grouping and history. Keep existing managed terminal and Claude navigation accessible.
- Historical record display and continuation; live control only if same-daemon capability and thread.canAcceptDirectInput permit it. UI distinguishes read-only states, and approval requests must remain actionable if remote continuation is enabled.
- Never send prompts or mutate actual user sessions during implementation testing. Use injected RPC fixtures and isolated test data.

## Boundaries and verification
Server setup/deployment files, agent config/main, relay startup; separate Codex bridge/core/protocol; Flutter model/controller/sidebar/session widgets/tests; docs.
Node checks + targeted tests, Flutter analyze/tests, typed protocol integration, real read-only daemon listing. Docker runtime unavailable on PATH initially: inspect files and record limitation; do not claim container run without evidence. APK build uses documented temporary NDK override if needed.
