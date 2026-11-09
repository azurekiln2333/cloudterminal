# Implementation

- [x] Audit existing code, Trellis records, and baseline checks (41 Node tests; Flutter analyze clean).
- [x] Add PTY adapter/session, additive protocol, core routing and desktop terminal mode; run Node checks and tests.
- [x] Add mobile terminal model/controller/emulator/create UI and tests; run Flutter analyze/tests.
- [x] Verify real PTY and mobile-to-relay-to-agent flow, reconnect and lifecycle.
- [x] Independent quality review, fix findings, update specs and README.
- [ ] Record checked results and commit coherent changes.

Rollback: remove terminal additions and dependencies; original Claude APIs remain unchanged. Original task planning files are preserved as original-*.md.

Validation: Node typecheck clean; 47/47 Node tests including real desktop/PTY lifecycle; Flutter analyze clean; 26/27 Flutter tests including live Dart-to-Node PTY. Android debug APK built with temporary NDK 27 override; original Gradle config restored. Installed/launched on shared emulator; manual terminal UI smoke not completed because another app took foreground. Work commits and archival await the project workflow commit-plan confirmation.

## Authorized follow-up
See [desktop-integration.md](desktop-integration.md) for the 2026-10-03 requested easy deployment and Codex Desktop sidebar/control scope. Previous completion applies only to the terminal baseline; this follow-up remains in progress.

## Follow-up execution (resumed 2026-10-03)

- [x] Recover prior conversation/artifacts and activate the existing in-progress task without discarding dirty work.
- [x] Review and repair persisted startup preferences, relay registration keys and Docker entrypoints.
- [ ] Connect to the running Codex daemon, validate real read-only project/thread APIs, and cover control with injected fixtures.
- [ ] Finish responsive MD3 sidebar, typed history, continuation and approval UI.
- [ ] Run independent cross-layer review plus full Node and Flutter gates.
- [ ] Build an updated Android debug APK; restore temporary local NDK configuration.
- [ ] Synchronize README/specs and final audit, then present updated commit plan under workflow 3.4.

The previous 47/27 result only covers the terminal baseline. Follow-up verification must be recorded separately. No actual user Codex thread may receive a test prompt or mutation. Docker is absent on this host, and no Android device is attached as of resume; container startup and device smoke are not inferred from unit/widget tests.

## Server-only upload package (2026-10-07)

- [x] Consolidate Compose, Dockerfile, Caddy, thin dependency manifest and deployment instructions in server/.
- [x] Preserve default Compose project/volume identity with name: cloudterminal in both entries.
- [x] Verify local build inputs and runtime imports; Node typecheck and git diff --check pass.
- [x] Create build/deploy/cloudterminal-relay-deploy.zip: 16 allowlisted files, CRC and source-byte equality verified; user-owned server.zip untouched.
- [x] Update README and backend deployment/layout specs.

Docker is unavailable on this host, so image build/container startup are not claimed. This packaging delivery does not complete the outstanding Codex bridge/control review, cross-language tests, updated APK or commit workflow.
