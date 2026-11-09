# Flutter Lifecycle Guidelines

This app uses Flutter lifecycle methods/listenables, not React hooks. This filename remains stable for existing Trellis context references.

`lib/main.dart` owns the app controller and appearance controller. RemoteController owns the socket/reconnect loop; screens must not create competing sockets or retry loops.

ListenableBuilder observes ChangeNotifier. SessionScreen obtains the session view and subscribes on open, unsubscribes on disposal, and disposes input/scroll controllers. PairScreen likewise disposes all text controllers.

```dart
@override
void dispose() {
  _input.dispose();
  _scroll.dispose();
  super.dispose();
}
```

Keep session unsubscribe alongside local cleanup; closing a screen must not terminate its desktop process.

Do not fetch from build. Start operations in lifecycle/action handlers, then check mounted/context.mounted after await. Direct test listeners are removed in whenComplete (`test/node_integration_test.dart`). App resume uses the controller reconnect mechanism in `lib/main.dart`.
