import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/herdr.dart';
import 'remote_controller.dart';

/// Caches Herdr state for the UI and serialises control actions.
///
/// Reads are request/response only (no push stream), so refreshes are explicit:
/// on first open, on reconnect, on pull-to-refresh, and after every successful
/// mutation. Actions are guarded by [_inFlight] so a double tap cannot send the
/// same mutating command twice.
class HerdrController extends ChangeNotifier {
  HerdrController(this._remote) {
    _wasOnline = _remote.isOnline;
    _remote.addListener(_onRemote);
  }

  final RemoteController _remote;
  bool _disposed = false;
  bool _wasOnline = false;

  /// Exposed so screens can build actions without a second controller reference.
  RemoteController get remoteController => _remote;

  HerdrAvailability? _availability;
  List<HerdrWorkspace> _workspaces = const <HerdrWorkspace>[];
  List<HerdrAgent> _agents = const <HerdrAgent>[];
  final Map<String, List<HerdrTab>> _tabs = <String, List<HerdrTab>>{};
  final Map<String, List<HerdrPane>> _panes = <String, List<HerdrPane>>{};
  final Map<String, HerdrLayout> _layouts = <String, HerdrLayout>{};
  final Set<String> _inFlight = <String>{};
  bool _loading = false;
  bool _loaded = false;
  bool _probing = false;
  bool _probeFailed = false;
  String? _error;
  Future<void>? _inflightRefresh;

  HerdrAvailability? get availability => _availability;
  List<HerdrWorkspace> get workspaces => _workspaces;
  List<HerdrAgent> get agents => _agents;
  bool get loading => _loading;
  bool get loaded => _loaded;
  String? get error => _error;

  /// A probe is currently running; the UI shows "detecting" rather than a
  /// verdict while this is true.
  bool get probing => _probing;

  /// The bridge capability has been established: either the agent answered with
  /// an availability report, or the probe request itself failed. Until then the
  /// answer is genuinely *unknown* — which must never be rendered as "disabled".
  bool get probed => _availability != null || _probeFailed;

  /// True when the desktop agent reports Herdr and it is ready to be driven.
  ///
  /// Gates **mutating** actions only; browsing uses [canBrowse] so an
  /// unprobed or unavailable bridge can still be inspected.
  bool get canControl =>
      _remote.isOnline && (_availability?.available ?? false);

  /// True when the pair link is up, so the Herdr destination can be opened to
  /// show either real data or the reason it is unavailable.
  bool get canBrowse => _remote.isOnline;

  /// Set of action keys currently being executed; the UI disables them.
  Set<String> get inFlight => _inFlight;

  bool isBusy(String key) => _inFlight.contains(key);

  List<HerdrTab> tabs(String workspaceId) =>
      _tabs[workspaceId] ?? const <HerdrTab>[];

  List<HerdrPane> panes(String workspaceId) =>
      _panes[workspaceId] ?? const <HerdrPane>[];

  HerdrLayout? layout(String paneId) => _layouts[paneId];

  /// Agents hosted in [workspaceId], most attention-needing first.
  List<HerdrAgent> agentsIn(String workspaceId) {
    final list = _agents.where((a) => a.workspaceId == workspaceId).toList()
      ..sort((a, b) {
        final na = a.needsAttention ? 1 : 0;
        final nb = b.needsAttention ? 1 : 0;
        if (na != nb) return nb - na;
        return a.paneId.compareTo(b.paneId);
      });
    return list;
  }

  /// How many live agents need the user (blocked or finished-unseen).
  int get attentionCount =>
      _agents.where((a) => a.needsAttention).length;

  // -------------------------------------------------------------------------

  /// Tracks link transitions: probe once when the agent comes online (so the
  /// destination is usable without the user opening the page first), and clear
  /// cached state when it drops so stale Herdr data is never shown as live.
  void _onRemote() {
    final online = _remote.isOnline;
    if (online && !_wasOnline) {
      _wasOnline = true;
      // Not awaited: a listener cannot be async. refresh() is idempotent and
      // de-duplicated, so a concurrent page-init probe is harmless.
      unawaited(refresh());
    } else if (!online && _wasOnline) {
      _wasOnline = false;
      _loaded = false;
      _availability = null;
      _probeFailed = false;
      _error = null;
      _notify();
    }
  }

  /// Load availability plus the top-level listings.
  ///
  /// Concurrent non-forced calls share one request; `force` always issues a
  /// fresh probe because it expresses explicit user intent (pull-to-refresh).
  Future<void> refresh({bool force = false}) {
    if (!_remote.isOnline) {
      _error = '电脑未连接';
      _notify();
      return Future<void>.value();
    }
    final pending = _inflightRefresh;
    if (!force && pending != null) return pending;
    final future = _doRefresh(force: force);
    _inflightRefresh = future;
    return future.whenComplete(() {
      if (identical(_inflightRefresh, future)) _inflightRefresh = null;
    });
  }

  Future<void> _doRefresh({required bool force}) async {
    _loading = true;
    _probing = true;
    _error = null;
    _notify();
    try {
      final availability = await _remote.herdrInfo(force: force);
      _availability = availability;
      _probeFailed = false;
      if (!availability.available) {
        _workspaces = const <HerdrWorkspace>[];
        _agents = const <HerdrAgent>[];
        _tabs.clear();
        _panes.clear();
        _layouts.clear();
        _loaded = false;
        return;
      }
      final results = await Future.wait(<Future<Object>>[
        _remote.herdrWorkspaces(),
        _remote.herdrAgents(),
      ]);
      _workspaces = results[0] as List<HerdrWorkspace>;
      _agents = results[1] as List<HerdrAgent>;
      _loaded = true;
      // Drop cached detail for workspaces that no longer exist.
      final live = _workspaces.map((w) => w.workspaceId).toSet();
      _tabs.removeWhere((id, _) => !live.contains(id));
      _panes.removeWhere((id, _) => !live.contains(id));
    } on RemoteException catch (e) {
      _error = _cleanHerdrError(e.message);
      // The capability question was answered (negatively) by the failed
      // request, so stop advertising it as "unknown".
      _probeFailed = true;
    } finally {
      _loading = false;
      _probing = false;
      _notify();
    }
  }

  /// Load tabs and panes for one workspace (called when it is expanded).
  Future<void> loadWorkspace(String workspaceId, {bool force = false}) async {
    if (!canControl) return;
    if (!force && _tabs.containsKey(workspaceId) && _panes.containsKey(workspaceId)) {
      return;
    }
    try {
      final results = await Future.wait(<Future<Object>>[
        _remote.herdrTabs(workspaceId),
        _remote.herdrPanes(workspaceId),
      ]);
      _tabs[workspaceId] = results[0] as List<HerdrTab>;
      _panes[workspaceId] = results[1] as List<HerdrPane>;
      _notify();
    } on RemoteException catch (e) {
      _error = _cleanHerdrError(e.message);
      _notify();
    }
  }

  Future<void> loadLayout(String paneId, {bool force = false}) async {
    if (!canControl || (!force && _layouts.containsKey(paneId))) return;
    try {
      _layouts[paneId] = await _remote.herdrLayout(paneId);
      _notify();
    } on RemoteException catch (e) {
      _error = _cleanHerdrError(e.message);
      _notify();
    }
  }

  Future<HerdrOutput> read(
    String paneId, {
    HerdrReadSource source = HerdrReadSource.visible,
    int lines = 200,
  }) => _remote.herdrRead(paneId, source: source, lines: lines);

  /// Fire a mutating action once, refresh afterwards, and surface failures.
  ///
  /// The [key] identifies the UI control so it can be disabled while running;
  /// re-entrant calls for the same key are dropped rather than queued, which is
  /// what prevents a duplicate agent launch.
  Future<HerdrActionReport?> run(
    String key,
    Future<HerdrActionReport> Function() action, {
    bool refreshAfter = true,
  }) async {
    if (_inFlight.contains(key)) return null;
    _inFlight.add(key);
    _error = null;
    _notify();
    try {
      final report = await action();
      if (refreshAfter) await refresh();
      return report;
    } on RemoteException catch (e) {
      _error = _cleanHerdrError(e.message);
      rethrow;
    } finally {
      _inFlight.remove(key);
      _notify();
    }
  }

  /// Strip the stable wire prefix so the UI shows the actionable sentence.
  ///
  /// `herdr_failed:agent_blocked:agent 正在等待确认…` → `agent 正在等待确认…`
  static String _cleanHerdrError(String message) {
    var text = message;
    for (final prefix in const <String>[
      'herdr_unavailable',
      'herdr_invalid_argument',
      'herdr_failed',
    ]) {
      if (!text.startsWith('$prefix:')) continue;
      text = text.substring(prefix.length + 1);
      // A second segment is the raw Herdr code; drop it too.
      final colon = text.indexOf(':');
      if (colon > 0 && colon < 40 && !text.substring(0, colon).contains(' ')) {
        text = text.substring(colon + 1);
      }
      break;
    }
    return text;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _remote.removeListener(_onRemote);
    super.dispose();
  }
}
