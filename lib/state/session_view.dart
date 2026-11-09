import 'package:flutter/foundation.dart';
import 'package:xterm/xterm.dart';

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

  int _lastSeq = 0;
  int get lastSeq => _lastSeq;
  bool _replaying = false;
  Terminal? _terminal;
  void Function(String)? onTerminalInput;

  /// Keep the parsed screen across navigation, never an unbounded raw log.
  Terminal get terminal => _terminal ??= _createTerminal();

  Terminal _createTerminal() {
    final terminal = Terminal(maxLines: 2000);
    terminal.resize(
      (_info.cols ?? 80).clamp(2, 500),
      (_info.rows ?? 24).clamp(1, 300),
    );
    terminal.onOutput = (data) {
      if (!_replaying) onTerminalInput?.call(data);
    };
    return terminal;
  }

  ToolResultEvent? resultFor(String toolUseId) => _results[toolUseId];

  PermissionResolvedEvent? resolutionFor(String requestId) =>
      _resolved[requestId];

  /// Permission requests nobody has answered yet, oldest first.
  List<PermissionRequestEvent>
  get pendingPermissions => <PermissionRequestEvent>[
    for (final e in _events)
      if (e is PermissionRequestEvent && !_resolved.containsKey(e.requestId)) e,
  ];

  void updateInfo(SessionInfo info) {
    final terminal = _terminal;
    if (terminal != null &&
        info.cols != null &&
        info.rows != null &&
        (info.cols != _info.cols || info.rows != _info.rows)) {
      // Desktop/other clients can resize the shared PTY. Apply its geometry
      // without echoing another resize request back to the agent.
      final onResize = terminal.onResize;
      terminal.onResize = null;
      terminal.resize(info.cols!.clamp(2, 500), info.rows!.clamp(1, 300));
      terminal.onResize = onResize;
    }
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
      _lastSeq = 0;
      _terminal = null;
      _events.clear();
      _results.clear();
      _resolved.clear();
      _streaming = '';
    }
    _replaying = true;
    try {
      for (final e in events) {
        _add(e);
      }
    } finally {
      _replaying = false;
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
    _lastSeq = e.seq;
    if (e is TerminalOutputEvent) {
      terminal.write(e.data);
      return true;
    }
    _events.add(e);
    if (_info.isTerminal && _events.length > 100) _events.removeAt(0);
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
