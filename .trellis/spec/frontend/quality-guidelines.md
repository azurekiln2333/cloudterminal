# Frontend Quality Guidelines

analysis_options.yaml enables flutter_lints; pubspec.yaml requires Dart ^3.11.5. At root run `flutter analyze` and `flutter test`. Format changed Dart files. Do not lower SDK constraints just to conceal a missing local toolchain.

## Coverage

- test/remote_controller_test.dart: fake relay, pairing, errors, reconnect/replay, gone sessions, URL normalization, models.
- test/widgets_test.dart: rendering and interactions.
- test/node_integration_test.dart: actual WebSocket to Node relay/AgentCore with scripted Claude output; skips without server/node_modules/ws and needs node on PATH.

For wire changes, verify integration actually runs. Scripted tests do not verify Claude credentials. New controls need relevant controller/widget assertions; test offline/error behavior and disposal as well as success.

Keep phone keyboard insets, long output and busy actions usable. Native packaging/device tests are distinct from analyzer/widget results. Existing dart:io socket/store imports mean generated web scaffolding does not establish browser support.
