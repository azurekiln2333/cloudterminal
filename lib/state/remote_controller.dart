import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../models/protocol.dart';
import '../net/relay_socket.dart';
import 'app_store.dart';
import 'session_view.dart';

/// Where the link to the PC currently stands.
enum ConnectionPhase {
  /// No pairing saved yet.
  unpaired,

  /// Dialing the relay / waiting for hello_ok.
  connecting,

  /// Relay reachable and the PC agent is online.
  online,

  /// Relay reachable but the PC agent is not connected to it.
  agentOffline,

  /// Relay rejected our credentials; needs re-pairing.
  authFailed,

  /// Relay unreachable; retrying with backoff.
  disconnected,
}

class RemoteException implements Exception {
  const RemoteException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Owns the relay connection: pairing, reconnects, request/response
/// correlation, the session list, and live [SessionView]s.
class RemoteController extends ChangeNotifier {
  RemoteController({
    required AppStore store,
    RelayConnector connector = connectIoSocket,
    this.requestTimeout = const Duration(seconds: 20),
  })  : _store = store,
        _connector = connector,
        _pairing = store.pairing {
    if (_pairing == null) _phase = ConnectionPhase.unpaired;
  }

  final AppStore _store;
  final RelayConnector _connector;
  final Duration requestTimeout;

  Pairing? _pairing;
  ConnectionPhase _phase = ConnectionPhase.disconnected;
  String? _lastError;
  AgentInfo? _agent;
  final Map<String, SessionInfo> _sessions = <String, SessionInfo>{};
  final Map<String, SessionView> _views = <String, SessionView>{};
  final Set<String> _subscribed = <String>{};
  final Map<String, Completer<Json>> _pending = <String, Completer<Json>>{};
  final Map<String, Timer> _timeouts = <String, Timer>{};

  RelaySocket? _socket;
  StreamSubscription<Json>? _frameSub;
  Completer<void>? _socketDone;
  int _generation = 0;
  int _attempt = 0;
  int _nextId = 0;
  Completer<void>? _wake;
  bool _disposed = false;

  Pairing? get pairing => _pairing;
  ConnectionPhase get phase => _phase;
  bool get isOnline => _phase == ConnectionPhase.online;
  String? get lastError => _lastError;
  AgentInfo? get agent => _agent;

  /// Name to show for the PC.
  String get agentName {
    final name = _pairing?.name ?? '';
    if (name.isNotEmpty) return name;
    return _agent?.host ?? '我的电脑';
  }

  /// Sessions needing attention first, then most recently active.
  List<SessionInfo> get sessions {
    final list = _sessions.values.toList();
    list.sort((a, b) {
      final pa = a.pending > 0 ? 1 : 0;
      final pb = b.pending > 0 ? 1 : 0;
      if (pa != pb) return pb - pa;
      return b.updatedAt.compareTo(a.updatedAt);
    });
    return list;
  }

  int get pendingTotal =>
      _sessions.values.fold(0, (sum, s) => sum + s.pending);

  SessionInfo? session(String id) => _sessions[id];

  /// Live view for [id]. Created on first use and kept while the app runs.
  SessionView view(SessionInfo info) =>
      _views.putIfAbsent(info.id, () => SessionView(info));

  // -------------------------------------------------------------------------
  // Pairing
  // -------------------------------------------------------------------------

  /// Exchange a one-time code (shown by the PC agent) for credentials.
  Future<void> pairWithCode(String relayInput, String code) async {
    final url = _requireUrl(relayInput);
    final socket = await _connect(url);
    try {
      socket.send(<String, dynamic>{'t': 'hello', 'role': 'pair', 'code': code});
      final frame = await socket.frames.first
          .timeout(const Duration(seconds: 20), onTimeout: () {
        throw const RemoteException('配对超时，请检查网络后重试');
      });
      if (frame['t'] == 'paired') {
        await _savePairing(Pairing(
          relayUrl: url.toString(),
          agentId: frame['agentId'] as String,
          secret: frame['secret'] as String,
          name: frame['name'] as String? ?? '',
        ));
        return;
      }
      throw RemoteException(_relayErrorText(frame, pairing: true));
    } on StateError {
      throw const RemoteException('服务器关闭了连接');
    } finally {
      unawaited(socket.close());
    }
  }

  /// Manual pairing with the device ID and secret from agent.json.
  Future<void> pairManually(
    String relayInput,
    String agentId,
    String secret,
  ) async {
    final url = _requireUrl(relayInput);
    if (agentId.trim().isEmpty || secret.trim().isEmpty) {
      throw const RemoteException('请填写设备 ID 和密钥');
    }
    await _savePairing(Pairing(
      relayUrl: url.toString(),
      agentId: agentId.trim(),
      secret: secret.trim(),
    ));
  }

  Future<void> unpair() async {
    _generation++;
    _teardownSocket();
    _pairing = null;
    _agent = null;
    _sessions.clear();
    _views.clear();
    _subscribed.clear();
    _phase = ConnectionPhase.unpaired;
    _lastError = null;
    await _store.setPairing(null);
    _notify();
  }

  Future<void> _savePairing(Pairing pairing) async {
    await _store.setPairing(pairing);
    await _store.setString('lastRelayUrl', pairing.relayUrl);
    _pairing = pairing;
    _sessions.clear();
    _views.clear();
    _subscribed.clear();
    _lastError = null;
    connect();
  }

  Uri _requireUrl(String input) {
    final url = normalizeRelayUrl(input);
    if (url == null) throw const RemoteException('服务器地址格式不正确');
    return url;
  }

  // -------------------------------------------------------------------------
  // Connection loop
  // -------------------------------------------------------------------------

  /// Start (or restart) the connection loop for the saved pairing.
  void connect() {
    if (_pairing == null || _disposed) return;
    final gen = ++_generation;
    _teardownSocket();
    _attempt = 0;
    unawaited(_run(gen));
  }

  /// Skip the current backoff wait (app resumed, user tapped retry).
  void reconnectNow() {
    if (_pairing == null) return;
    if (_phase == ConnectionPhase.authFailed) {
      connect();
      return;
    }
    if (_socket == null) {
      _attempt = 0;
      final wake = _wake;
      if (wake != null && !wake.isCompleted) wake.complete();
    }
  }

  Future<void> _run(int gen) async {
    while (gen == _generation && !_disposed) {
      final pairing = _pairing;
      if (pairing == null) return;
      _setPhase(ConnectionPhase.connecting);
      Duration? retryAfter;
      try {
        final socket = await _connect(Uri.parse(pairing.relayUrl));
        if (gen != _generation) {
          unawaited(socket.close());
          return;
        }
        _socket = socket;
        socket.send(<String, dynamic>{
          't': 'hello',
          'role': 'client',
          'agentId': pairing.agentId,
          'secret': pairing.secret,
          'v': 1,
        });
        final done = _socketDone = Completer<void>();
        _frameSub = socket.frames.listen(
          (frame) {
            final after = _onFrame(frame);
            if (after != null) retryAfter = after;
          },
          onDone: () {
            if (!done.isCompleted) done.complete();
          },
          onError: (Object _) {
            if (!done.isCompleted) done.complete();
          },
          cancelOnError: true,
        );
        await done.future;
        if (gen != _generation) return;
        _socket = null;
        _failPending('与服务器的连接已断开');
        if (_phase == ConnectionPhase.authFailed) return;
      } on RemoteException catch (e) {
        _lastError = e.message;
      } catch (e) {
        _lastError = '无法连接服务器：$e';
      }
      if (gen != _generation || _disposed) return;
      if (_phase != ConnectionPhase.agentOffline) {
        _setPhase(ConnectionPhase.disconnected);
      }
      final delay = retryAfter ?? _backoff();
      _wake = Completer<void>();
      await Future.any(<Future<void>>[
        Future<void>.delayed(delay),
        _wake!.future,
      ]);
    }
  }

  Duration _backoff() {
    final seconds = min(30, pow(2, _attempt).toInt());
    _attempt = min(_attempt + 1, 6);
    final jitter = 0.75 + Random().nextDouble() * 0.5;
    return Duration(milliseconds: (seconds * 1000 * jitter).round());
  }

  Future<RelaySocket> _connect(Uri url) async {
    try {
      return await _connector(url);
    } on TimeoutException {
      throw const RemoteException('连接服务器超时');
    } catch (e) {
      throw RemoteException('无法连接服务器（$e）');
    }
  }

  /// Returns a custom retry delay when the relay asked us to back off.
  Duration? _onFrame(Json frame) {
    switch (frame['t']) {
      case 'hello_ok':
        _attempt = 0;
        _lastError = null;
        final name = frame['name'] as String?;
        if (name != null && name.isNotEmpty && name != _pairing?.name) {
          _pairing = _pairing?.copyWith(name: name);
          unawaited(_store.setPairing(_pairing));
        }
        if (frame['online'] == true) {
          _onAgentOnline();
        } else {
          _setPhase(ConnectionPhase.agentOffline);
        }
      case 'presence':
        if (frame['online'] == true) {
          _onAgentOnline();
        } else {
          _failPending('电脑已离线');
          _setPhase(ConnectionPhase.agentOffline);
        }
      case 'error':
        final code = frame['code'];
        if (code == 'unauthorized') {
          _lastError = '配对已失效，请重新配对';
          _setPhase(ConnectionPhase.authFailed);
        } else if (code == 'agent_offline') {
          _failPending('电脑已离线');
          _setPhase(ConnectionPhase.agentOffline);
        } else if (code == 'rate_limited') {
          _lastError = '尝试次数过多，请稍后再试';
          return const Duration(seconds: 60);
        } else {
          _lastError = frame['message'] as String?;
        }
      case 'msg':
        final data = frame['data'];
        if (data is Json) _onMessage(data);
    }
    return null;
  }

  void _onAgentOnline() {
    _setPhase(ConnectionPhase.online);
    unawaited(_refreshAfterConnect());
  }

  Future<void> _refreshAfterConnect() async {
    try {
      final info = await _request(<String, dynamic>{'type': 'info'});
      _agent = AgentInfo.fromJson(info);
      await refreshSessions();
      for (final id in _subscribed.toList()) {
        await _subscribe(id);
      }
      _notify();
    } on RemoteException catch (e) {
      _lastError = e.message;
      _notify();
    }
  }

  void _onMessage(Json data) {
    final kind = data['kind'];
    switch (kind) {
      case 'session':
        final raw = data['session'];
        if (raw is Json) _upsertSession(SessionInfo.fromJson(raw));
      case 'session_created':
        final raw = data['session'];
        if (raw is Json) _upsertSession(SessionInfo.fromJson(raw));
      case 'sessions':
        final list = data['sessions'];
        if (list is List) {
          final fresh = <String, SessionInfo>{
            for (final raw in list)
              if (raw is Json) raw['id'] as String: SessionInfo.fromJson(raw),
          };
          for (final entry in _views.entries) {
            if (!fresh.containsKey(entry.key)) entry.value.markGone();
          }
          _sessions
            ..clear()
            ..addAll(fresh);
          _notify();
        }
      case 'events':
        final view = _views[data['sessionId']];
        final list = data['events'];
        if (view != null && list is List) {
          view.applyBacklog(
            <SessionEvent>[
              for (final e in list)
                if (e is Json) SessionEvent.fromJson(e),
            ],
            reset: data['reset'] == true,
          );
        }
      case 'event':
        final raw = data['event'];
        if (raw is Json) _views[data['sessionId']]?.applyEvent(SessionEvent.fromJson(raw));
      case 'delta':
        final text = data['text'];
        if (text is String) _views[data['sessionId']]?.applyDelta(text);
    }

    final id = data['id'];
    if (id is String) {
      _timeouts.remove(id)?.cancel();
      final completer = _pending.remove(id);
      if (completer != null && !completer.isCompleted) {
        if (kind == 'error') {
          completer.completeError(
            RemoteException(data['message'] as String? ?? '请求失败'),
          );
        } else {
          completer.complete(data);
        }
      }
    }
  }

  void _upsertSession(SessionInfo info) {
    _sessions[info.id] = info;
    _views[info.id]?.updateInfo(info);
    _notify();
  }

  // -------------------------------------------------------------------------
  // Requests
  // -------------------------------------------------------------------------

  Future<Json> _request(Json body) {
    final socket = _socket;
    if (socket == null || _phase != ConnectionPhase.online) {
      return Future<Json>.error(const RemoteException('电脑未连接'));
    }
    final id = 'r${++_nextId}';
    final completer = Completer<Json>();
    _pending[id] = completer;
    _timeouts[id] = Timer(requestTimeout, () {
      _timeouts.remove(id);
      _pending.remove(id)?.completeError(const RemoteException('请求超时'));
    });
    socket.send(<String, dynamic>{
      't': 'msg',
      'data': <String, dynamic>{...body, 'id': id},
    });
    return completer.future;
  }

  void _failPending(String message) {
    for (final t in _timeouts.values) {
      t.cancel();
    }
    _timeouts.clear();
    final pending = _pending.values.toList();
    _pending.clear();
    for (final c in pending) {
      if (!c.isCompleted) c.completeError(RemoteException(message));
    }
  }

  Future<void> refreshSessions() async {
    await _request(<String, dynamic>{'type': 'list_sessions'});
  }

  Future<List<HistoryItem>> history({String? cwd}) async {
    final reply = await _request(<String, dynamic>{
      'type': 'list_history',
      'cwd': ?cwd,
    });
    return <HistoryItem>[
      for (final raw in (reply['items'] as List<dynamic>? ?? <dynamic>[]))
        if (raw is Json) HistoryItem.fromJson(raw),
    ];
  }

  Future<DirListing> listDir([String? path]) async {
    final reply = await _request(<String, dynamic>{
      'type': 'list_dir',
      if (path != null && path.isNotEmpty) 'path': path,
    });
    return DirListing.fromJson(reply);
  }

  Future<SessionInfo> createSession({
    required String cwd,
    String? prompt,
    String mode = PermissionModes.defaultMode,
    String? resume,
  }) async {
    final reply = await _request(<String, dynamic>{
      'type': 'create_session',
      'cwd': cwd,
      if (prompt != null && prompt.trim().isNotEmpty) 'prompt': prompt,
      'mode': mode,
      'resume': ?resume,
    });
    final info = SessionInfo.fromJson(reply['session'] as Json);
    _upsertSession(info);
    return info;
  }

  /// Start streaming [id] into its view (backlog first, then live events).
  Future<void> subscribe(String id) async {
    _subscribed.add(id);
    await _subscribe(id);
  }

  Future<void> _subscribe(String id) async {
    final view = _views[id];
    try {
      await _request(<String, dynamic>{
        'type': 'subscribe',
        'sessionId': id,
        'afterSeq': view?.lastSeq ?? 0,
      });
    } on RemoteException {
      if (!_sessions.containsKey(id)) view?.markGone();
      rethrow;
    }
  }

  void unsubscribe(String id) {
    _subscribed.remove(id);
    if (isOnline) {
      unawaited(
        _request(<String, dynamic>{'type': 'unsubscribe', 'sessionId': id})
            .then((_) {}, onError: (Object _) {}),
      );
    }
  }

  Future<void> send(String sessionId, String text) =>
      _request(<String, dynamic>{
        'type': 'send',
        'sessionId': sessionId,
        'text': text,
      });

  Future<void> interrupt(String sessionId) =>
      _request(<String, dynamic>{'type': 'interrupt', 'sessionId': sessionId});

  /// [decision] is allow | allow_always | deny.
  Future<void> respondPermission(
    String sessionId,
    String requestId,
    String decision, {
    String? message,
    Map<String, String>? answers,
  }) =>
      _request(<String, dynamic>{
        'type': 'permission',
        'sessionId': sessionId,
        'requestId': requestId,
        'decision': decision,
        if (message != null && message.trim().isNotEmpty) 'message': message,
        'answers': ?answers,
      });

  Future<void> setMode(String sessionId, String mode) =>
      _request(<String, dynamic>{
        'type': 'set_mode',
        'sessionId': sessionId,
        'mode': mode,
      });

  Future<void> closeSession(String sessionId) async {
    await _request(<String, dynamic>{
      'type': 'close_session',
      'sessionId': sessionId,
    });
    _sessions.remove(sessionId);
    _subscribed.remove(sessionId);
    _views.remove(sessionId)?.markGone();
    _notify();
  }

  // -------------------------------------------------------------------------

  void _setPhase(ConnectionPhase phase) {
    if (_phase == phase) return;
    _phase = phase;
    _notify();
  }

  void _teardownSocket() {
    unawaited(_frameSub?.cancel());
    _frameSub = null;
    final done = _socketDone;
    _socketDone = null;
    if (done != null && !done.isCompleted) done.complete();
    final socket = _socket;
    _socket = null;
    if (socket != null) unawaited(socket.close());
    _failPending('连接已重置');
    final wake = _wake;
    if (wake != null && !wake.isCompleted) wake.complete();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _teardownSocket();
    super.dispose();
  }
}

String _relayErrorText(Json frame, {bool pairing = false}) {
  switch (frame['code']) {
    case 'unauthorized':
      return pairing ? '配对码无效或已过期，请在电脑上按回车生成新的配对码' : '配对已失效，请重新配对';
    case 'agent_offline':
      return '电脑不在线，请确认 agent 正在运行';
    case 'rate_limited':
      return '尝试次数过多，请稍后再试';
    case 'timeout':
      return '电脑没有响应，请重试';
    default:
      return (frame['message'] as String?) ?? '服务器返回了未知错误';
  }
}
