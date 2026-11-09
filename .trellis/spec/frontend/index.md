# Frontend Development Guidelines

Flutter application in `lib/`. Before editing, read Directory Structure and the relevant topic. Wire changes require the TypeScript producer and Dart model together. Reuse AppTheme and existing screens/sheets; do not insert fake production sessions.

| Guide | Scope | Status |
| --- | --- | --- |
| [Directory Structure](./directory-structure.md) | Layers and dependencies | Source-verified |
| [Components](./component-guidelines.md) | Widgets, async actions, styling | Source-verified |
| [Lifecycle](./hook-guidelines.md) | Flutter lifecycle, not React hooks | Source-verified |
| [State](./state-management.md) | Controller, session view, persistence | Source-verified |
| [Quality](./quality-guidelines.md) | Analyzer and test boundaries | Source-verified |
| [Types](./type-safety.md) | Typed models and wire parsing | Source-verified |
| [Herdr UI](./herdr-ui.md) | Herdr models, controller, screens and no-fake-data rule | Source-verified |
| [Debug devices](./debug-devices.md) | Real HarmonyOS / Android devices for runtime verification | Device-verified |

## Quality Gate

At root: `flutter analyze`, then `flutter test`. Node integration needs installed server dependencies and Node on PATH; report skipped integration explicitly. Specs are written in English.

**Runtime verification is a separate gate.** `flutter test` runs on the host platform and
cannot prove behaviour on a target platform. Before claiming a mobile change works on
OHOS, run it on the real device listed in [debug devices](./debug-devices.md). An
Android pass is not an OHOS pass.

See [Terminal wire contract](../backend/terminal-protocol.md) before changing PTY data, replay or geometry.
See [Herdr wire contract](../backend/herdr-protocol.md) and [Herdr UI](./herdr-ui.md) before changing Herdr listings, output or controls.
