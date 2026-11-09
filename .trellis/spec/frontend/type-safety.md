# Dart Types and Wire Decoding

lib/models/protocol.dart mirrors server/src/shared/protocol.ts. Json is Map<String, dynamic> at the boundary; widgets consume SessionInfo, DirListing and sealed SessionEvent subclasses. Keep raw frames out of UI business logic.

Unknown fields are ignored, unknown event kinds produce UnknownEvent, unknown statuses currently default to idle. Existing optional casts can still throw for wrong types: tolerant parsing is not complete schema validation.

## Numeric and Optional Fields

Use _str, _int, _double and _time helpers. Wire numbers may decode as int or double; timestamps are epoch milliseconds. Arbitrary tool input is Object?, not necessarily a map.

```dart
int _int(Object? v) => v is num ? v.toInt() : 0;
double _double(Object? v) => v is num ? v.toDouble() : 0;
```

Guard collections/items before model construction (if raw is Json). Prefer final model fields and named typed parameters.

## Transport

lib/net/relay_socket.dart filters non-string frames, malformed JSON and non-object payloads. RelaySocket provides the fake transport seam. normalizeRelayUrl maps HTTP to WebSocket schemes, adds /ws for empty/root paths, preserves custom paths and drops queries; assertions are in test/remote_controller_test.dart.

Do not assume every event has text, directly cast a frame into a model, or rename a field on only one side. Add parser assertions for new kinds while retaining unknown-kind behavior.
