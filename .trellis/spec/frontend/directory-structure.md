# Frontend Directory Structure

Flutter Material 3 application. Native transport/storage use dart:io; generated web scaffolding does not mean the app supports browsers. Platform build availability must be verified separately.

```text
lib/
  main.dart                app ownership, lifecycle, pairing/home selection
  models/protocol.dart     Dart mirror of server/src/shared/protocol.ts
  net/relay_socket.dart    RelaySocket seam, dart:io implementation, URLs
  state/
    remote_controller.dart connection, requests, list, subscriptions
    session_view.dart      per-session events and replay
    app_store.dart         app-private pairing/preferences JSON
    appearance.dart        theme preferences
  screens/                 pair, home, session
  widgets/                 sheets, cards, event/permission presentation
  theme/app_theme.dart     Material 3 themes and mono text style
  util/format.dart         shared presentation helpers
```

## Rules

Use ChangeNotifier + ListenableBuilder; streamed fragments notify the session view rather than rebuilding the app controller. Network changes go through RelaySocket so `test/support/fake_relay.dart` remains usable. Avoid WebSocket plugins when dart:io handles the existing native targets.

Use Chinese UI copy, explicit generic collections and existing theme surfaces/radii. Decode wire data into models; ignore unknown fields and preserve UnknownEvent fallback. Terminal rendering dependencies declared in pubspec.yaml must remain separate from transport and request correlation.
