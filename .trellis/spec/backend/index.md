# Backend Development Guidelines

The `server/` package contains the relay and desktop agent. Read Directory Structure before editing, then the relevant guide. For wire changes, read `server/src/shared/protocol.ts` and `lib/models/protocol.dart` together.

| Guide | Scope | Status |
| --- | --- | --- |
| [Directory Structure](./directory-structure.md) | Runtime and module boundaries | Source-verified |
| [Persistence](./database-guidelines.md) | Files and in-memory state; no database | Source-verified |
| [Errors](./error-handling.md) | Agent and relay failure contracts | Source-verified |
| [Quality](./quality-guidelines.md) | Type checking and tests | Source-verified |
| [Logging](./logging-guidelines.md) | Injected logger and sensitive fields | Source-verified |
| [Deployment](./deployment.md) | Desktop setup, Compose and relay key persistence | Source-verified |
| [Herdr wire contract](./herdr-protocol.md) | Local Herdr CLI bridge, validation and errors | Source-verified |
| [Windows client / sidecar](./sidecar-protocol.md) | Flutter Windows client IPC, tool bindings and pairing URI | Source-verified |

## Quality Gate

From `server/`: `npm run check` and `npm test`. Wire changes also require Flutter analyzer/controller/integration coverage. Scripted SDK tests do not prove real model authentication or phone connectivity. Specs are written in English.

See [Terminal wire contract](./terminal-protocol.md) before changing PTY data, replay or geometry.
See [Herdr wire contract](./herdr-protocol.md) before changing the local Herdr bridge, its validation or error codes.
See [Windows client / sidecar](./sidecar-protocol.md) before changing the Windows assistant IPC, tool bindings or pairing URI.
