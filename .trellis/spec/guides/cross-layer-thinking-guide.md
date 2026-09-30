# Cross-Layer Thinking Guide

The phone app, relay and agent share one wire protocol.

## The protocol has two copies

`server/src/shared/protocol.ts` is the source of truth;
`lib/models/protocol.dart` mirrors it. Changing a message or event means:

1. Update `protocol.ts` and the producer (`core.ts` / `normalize.ts` / `relay.ts`).
2. Update `protocol.dart` parsing and the consumer (`remote_controller.dart`,
   `session_view.dart`, widgets).
3. Add the field to `test/support/fake_relay.dart` if the fake agent sends it.
4. Run `test/node_integration_test.dart` — it is the only test that exercises
   the real Node side from Dart and catches shape mismatches.

Every agent reply to a request must echo the request `id`; the app
correlates on it and times out otherwise.

## Compatibility

Add fields, don't rename or remove them: the phone and the PC update
independently. The app ignores unknown fields and event kinds.

## Gotchas found so far

- XML comments cannot contain `--`; mentioning CLI flags like `--local-relay`
  in `AndroidManifest.xml` or `Info.plist` comments breaks the build.
- On Windows, `Process.start(..., runInShell: true)` + `kill()` orphans the
  node child and leaves its port bound.
