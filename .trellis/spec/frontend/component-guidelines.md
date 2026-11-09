# Component Guidelines

Widgets use named typed constructor parameters, super.key and final fields. Use StatelessWidget for provided state (`lib/widgets/session_card.dart`) and StatefulWidget for input, busy state and selection (`lib/widgets/new_session_sheet.dart`, `lib/widgets/permission_card.dart`). Pass RemoteController explicitly; widgets call methods instead of sending socket frames.

## Composition and Styling

Screens live in `lib/screens/`; cards, sheets and event renderers in `lib/widgets/`. Reuse AppTheme.mono and Material 3 ColorScheme surfaces. UI copy is Chinese. Formatting lives in `lib/util/format.dart` and `lib/widgets/tool_format.dart`. Use explicit generic collections such as `<Widget>[]`.

Bottom sheets account for `MediaQuery.viewInsetsOf(context).bottom`; keep forms scrollable on phones. Preserve selectable output and long-line scrolling.

## Async Actions

PairScreen/NewSessionSheet set busy, disable repeated submissions, display RemoteException.message and clear busy if mounted:

```dart
if (mounted) setState(() => _busy = false);
```

Check context.mounted before navigation after await. Icon actions have Chinese tooltips (send, stop, history). Avoid direct networking in widgets or rebuilding the whole app on each streamed fragment. A local failed action belongs in local UI state.
