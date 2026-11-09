# State Management

There is no Provider/Riverpod/Bloc layer. RemoteController, SessionView and AppearanceController use ChangeNotifier and ListenableBuilder.

| State | Owner |
| --- | --- |
| Pairing, connection, agent, IDs/timers, sessions, subscriptions | lib/state/remote_controller.dart |
| Ordered events, streaming, tool results, permissions, replay | lib/state/session_view.dart |
| Pairing/preferences JSON | lib/state/app_store.dart |
| Theme preferences | lib/state/appearance.dart |
| Input, busy/error, selection and scroll | Widget State |

## Connections

ConnectionPhase distinguishes online from agentOffline, connecting, disconnected, authFailed and unpaired. Relay reachability is not agent availability. Requests use IDs/completers and a 20-second default timeout. Disconnect/offline fails pending requests.

Reconnect refreshes agent/session info and resubscribes views. Missing sessions are marked gone; one missing session must not block others (`test/remote_controller_test.dart`).

## Replay and Streaming

SessionView.applyBacklog(reset: true) clears events/results/resolutions before replay. Duplicate events are ignored:

```dart
if (e.seq <= lastSeq) return false;
```

Streaming updates only the session view. Stored assistant/tool/result/error events supersede transient streamed text. Do not append the same server event from a widget or optimistically resolve permissions before the remote result.

## Persistence

AppStore reads cloudterminal.json in the application support directory, writes a temporary file then renames. During open, missing plugin/filesystem errors can fall back to memory and corrupt JSON starts empty. This is app-private plaintext, not encryption. Do not copy secrets to logs/external storage. Tests use AppStore.memory and fake relay state. Production empty states reflect actual sessions.
