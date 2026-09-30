# Directory Structure (lib/)

Flutter app (Material 3), targets Android / iOS / OpenHarmony. UI language
and theme follow `D:\MyNewProjects\terminax`.

```
lib/
├── main.dart            # app root; swaps PairScreen / HomeScreen on pairing
├── models/protocol.dart # Dart mirror of server/src/shared/protocol.ts
├── net/relay_socket.dart# RelaySocket interface + dart:io impl, URL normalization
├── state/
│   ├── remote_controller.dart # connection loop, requests, session list
│   ├── session_view.dart      # per-session transcript (ChangeNotifier)
│   ├── app_store.dart         # JSON file in app support dir (pairing, prefs)
│   └── appearance.dart
├── screens/             # pair / home / session
├── widgets/             # sheets, cards, event tiles, permission card
├── theme/app_theme.dart # seeded MD3 theme + mono text style
└── util/format.dart
```

## Rules

- State is `ChangeNotifier` + `ListenableBuilder` (same as terminax); no
  state-management packages. Streaming deltas notify only the `SessionView`,
  not the controller.
- Networking goes through `RelaySocket` so tests use `test/support/fake_relay.dart`.
  Do not add plugins for WebSocket; `dart:io` works on OpenHarmony.
- Explicit generic literals (`<Widget>[...]`, `<String, dynamic>{...}`),
  Chinese UI copy, `surfaceContainer*` colours, 12–20 px radii.
- Parsing from the wire is lenient: unknown fields ignored, unknown event
  kinds become `UnknownEvent`.
