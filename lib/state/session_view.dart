import 'package:flutter/foundation.dart';

import '../models/protocol.dart';

/// Everything the session screen renders for one session. Separate from
/// [RemoteController] so streaming deltas only rebuild the open session.
class SessionView extends ChangeNotifier {
  SessionView(this._info);

  SessionInfo _info;
  final List<SessionEvent> _events = <SessionEvent>[];
  final Map<String, ToolResultEvent> _results = <String, ToolResultEvent>{};
  final Map<String, PermissionResolvedEvent> _resolved =
      <String, PermissionResolvedEvent>{};
  String _streaming = '';
  bool _gone = false;
  bool _loaded = false;

  SessionInfo get info => _info;
  String get id => _info.id;

  /// Every event, in order (tool results and resolutions included).
  List<SessionEvent> get events => List<SessionEvent>.unmodifiable(_events);

  /// Assistant text still being streamed (not yet a stored event).
  String get streaming => _streaming;

  /// Session no longer exists on the agent (closed elsewhere / agent restart).
  bool get gone => _gone;

  /// First backlog has arrived.
  bool get loaded => _loaded;

  int get lastSeq => _events.isEmpty ? 0 : _events.last.seq;

  ToolResultEvent? resultFor(String toolUseId) => _results[toolUseId];

  PermissionResolvedEvent? resolutionFor(String requestId) =>
      _resolved[requestId];

  /// Permission requests nobody has answered yet, oldest first.
  List<PermissionRequestEvent> get pendingPermissions => <PermissionRequestEvent>[
        for (final e in _events)
          if (e is PermissionRequestEvent && !_resolved.containsKey(e.requestId))
            e,
      ];

  void updateInfo(SessionInfo info) {
    _info = info;
    if (info.isClosed || info.status == SessionStatus.idle) _streaming = '';
    notifyListeners();
  }

  void markGone() {
    _gone = true;
    notifyListeners();
  }

  void applyBacklog(List<SessionEvent> events, {required bool reset}) {
    if (reset) {
      _events.clear();
      _results.clear();
      _resolved.clear();
      _streaming = '';
    }
    for (final e in events) {
      _add(e);
    }
    _loaded = true;
    _gone = false;
    notifyListeners();
  }

  void applyEvent(SessionEvent event) {
    if (_add(event)) notifyListeners();
  }

  void applyDelta(String text) {
    _streaming += text;
    notifyListeners();
  }

  bool _add(SessionEvent e) {
    if (e.seq <= lastSeq) return false; // duplicate from a resubscribe race
    _events.add(e);
    switch (e) {
      case ToolResultEvent():
        _results[e.toolUseId] = e;
      case PermissionResolvedEvent():
        _resolved[e.requestId] = e;
      case AssistantEvent() || ToolUseEvent() || ResultEvent() || ErrorEvent():
        // The stored message supersedes whatever was streamed for it.
        _streaming = '';
      default:
        break;
    }
    return true;
  }
}
