import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../models/herdr.dart';
import '../models/pairing_uri.dart';
import '../models/protocol.dart';
import '../net/relay_socket.dart';
import 'app_store.dart';
import 'session_view.dart';

///
/// Receives Herdr push messages from [RemoteController] so the wire layer does
/// not need to know how the Herdr caches are laid out.
///
/// Deliberately narrow: one method per push kind. Unknown kinds never reach here
/// because the dispatcher matches on the exact `kind` string.
abstract interface class HerdrPushSink {
  /// A delta for one pane's screen text.
  void applyPaneOutput({
    required String paneId,
    required bool reset,
    required int prefix,
    required String chunk,

    /// Wire format of the payload; `ansi` under the current contract.
    String format,
  });

  /// A structure change: only the parts present in [message] changed.
  void applyStructure(Json message);
}

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

/// What [RemoteController.pairWithQr] did with a scanned / pasted payload.
enum QrPairStatus {
  /// Credentials were exchanged; the connection loop is already running.
  paired,

  /// The payload points at a different relay than the last pairing; the user
  /// must confirm before the app switches servers.
  needsRelayConfirm,
}

/// Result of [RemoteController.pairWithQr].
class QrPairResult {
  const QrPairResult({
    required this.status,
    required this.relayUrl,
    required this.previousRelayUrl,
  });

  final QrPairStatus status;

  /// Normalized relay from the payload (`ws` / `wss`).
  final String relayUrl;

  /// Relay last used on this phone, when there is one.
  final String? previousRelayUrl;

  bool get needsRelayConfirm => status == QrPairStatus.needsRelayConfirm;

  /// Host of the relay being connected. Falls back to the raw string when the
  /// URL cannot be split, so the prompt never renders empty.
  String get relayHost => Uri.tryParse(relayUrl)?.host ?? relayUrl;

  String? get previousRelayHost {
    final previous = previousRelayUrl;
    if (previous == null) return null;
    return Uri.tryParse(previous)?.host ?? previous;
  }
}

/// Owns the relay connection: pairing, reconnects, request/response
/// correlation, the session list, and live [SessionView]s.
class RemoteController extends ChangeNotifier {
  RemoteController({
    required AppStore store,
    RelayConnector connector = connectIoSocket,
    this.requestTimeout = const Duration(seconds: 20),
  }) : _store = store,
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
  int _infoEpoch = 0;
  bool _herdrPasteReady = false;
  final Map<String, SessionInfo> _sessions = <String, SessionInfo>{};
  final Map<String, SessionView> _views = <String, SessionView>{};
  final Set<String> _subscribed = <String>{};
  final Map<String, Completer<Json>> _pending = <String, Completer<Json>>{};
  final Map<String, Timer> _timeouts = <String, Timer>{};
  final StreamController<CodexNotice> _codexNotices =
      StreamController<CodexNotice>.broadcast();

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
  Stream<CodexNotice> get codexNotices => _codexNotices.stream;

  /// Sink for Herdr push messages.
  ///
  /// A single slot, set by the one `HerdrController` the app owns. Kept as an
  /// interface rather than a direct dependency so the wire layer stays unaware of
  /// Herdr's cache layout.
  HerdrPushSink? _herdrSink;

  void setHerdrSink(HerdrPushSink? sink) {
    _herdrSink = sink;
  }

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

  int get pendingTotal => _sessions.values.fold(0, (sum, s) => sum + s.pending);

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
      socket.send(<String, dynamic>{
        't': 'hello',
        'role': 'pair',
        'code': code,
      });
      final frame = await socket.frames.first.timeout(
        const Duration(seconds: 20),
        onTimeout: () {
          throw const RemoteException('配对超时，请检查网络后重试');
        },
      );
      if (frame['t'] == 'paired') {
        await _savePairing(
          Pairing(
            relayUrl: url.toString(),
            agentId: frame['agentId'] as String,
            secret: frame['secret'] as String,
            name: frame['name'] as String? ?? '',
          ),
        );
        return;
      }
      throw RemoteException(_relayErrorText(frame, pairing: true));
    } on StateError {
      throw const RemoteException('服务器关闭了连接');
    } finally {
      unawaited(socket.close());
    }
  }

  /// Pair a fresh PC from a scanned QR code / pasted pairing link.
  ///
  /// Parses a `cloudterminal://pair?...` payload and hands the relay + code to
  /// [pairWithCode]. A payload naming a relay other than the last one is
  /// *not* applied until the caller re-runs this with `confirmed: true`, so the
  /// UI can warn "将连接新服务器" first.
  ///
  /// Throws [RemoteException] when the payload is not a pairing link.
  Future<QrPairResult> pairWithQr(
    String payload, {
    bool confirmed = false,
  }) async {
    final parsed = PairingUri.tryParse(payload);
    if (parsed == null) {
      throw const RemoteException('无法识别配对二维码，请确认扫描的是 CloudTerminal 生成的二维码');
    }
    final relayUrl = parsed.relay.toString();
    final previous = _pairing?.relayUrl ?? _store.lastRelayUrl;
    if (!confirmed &&
        previous != null &&
        previous.isNotEmpty &&
        previous != relayUrl) {
      return QrPairResult(
        status: QrPairStatus.needsRelayConfirm,
        relayUrl: relayUrl,
        previousRelayUrl: previous,
      );
    }
    await pairWithCode(relayUrl, parsed.code);
    return QrPairResult(
      status: QrPairStatus.paired,
      relayUrl: relayUrl,
      previousRelayUrl: previous,
    );
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
    await _savePairing(
      Pairing(
        relayUrl: url.toString(),
        agentId: agentId.trim(),
        secret: secret.trim(),
      ),
    );
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
    final infoEpoch = ++_infoEpoch;
    _herdrPasteReady = false;
    _setPhase(ConnectionPhase.online);
    unawaited(_refreshAfterConnect(infoEpoch));
  }

  Future<void> _refreshAfterConnect(int infoEpoch) async {
    try {
      final info = await _request(<String, dynamic>{'type': 'info'});
      if (_disposed || !isOnline || infoEpoch != _infoEpoch) return;
      _agent = AgentInfo.fromJson(info);
      _herdrPasteReady = _agent!.capabilities.contains('herdr_paste');
      await refreshSessions();
      for (final id in _subscribed.toList()) {
        // Sessions that vanished (agent restarted) were marked gone by the
        // list refresh; one of them failing must not block the others.
        if (!_sessions.containsKey(id)) continue;
        try {
          await _subscribe(id);
        } on RemoteException {
          // Surfaced on the session screen; keep resubscribing the rest.
        }
      }
      _notify();
    } on RemoteException catch (e) {
      if (_disposed || infoEpoch != _infoEpoch) return;
      _lastError = e.message;
      _notify();
    }
  }

  void _onMessage(Json data) {
    final kind = data['kind'];
    switch (kind) {
      case 'codex_changed':
      case 'codex_pending':
        if (!_disposed) {
          _codexNotices.add(
            CodexNotice(
              data['threadId'] is String ? data['threadId'] as String : null,
            ),
          );
        }
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
            if (!fresh.containsKey(entry.key)) {
              entry.value.markGone();
            } else {
              entry.value.updateInfo(fresh[entry.key]!);
            }
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
          view.applyBacklog(<SessionEvent>[
            for (final e in list)
              if (e is Json) SessionEvent.fromJson(e),
          ], reset: data['reset'] == true);
        }
      case 'event':
        final raw = data['event'];
        if (raw is Json) {
          _views[data['sessionId']]?.applyEvent(SessionEvent.fromJson(raw));
        }
      case 'delta':
        final text = data['text'];
        if (text is String) _views[data['sessionId']]?.applyDelta(text);
      // Herdr pushes (no request id). Unknown push kinds are ignored, so a newer
      // agent never breaks an older app.
      case 'herdr_pane_output':
        _herdrSink?.applyPaneOutput(
          paneId: data['paneId'] is String ? data['paneId'] as String : '',
          reset: data['reset'] == true,
          prefix: data['prefix'] is num ? (data['prefix'] as num).toInt() : 0,
          chunk: data['chunk'] is String ? data['chunk'] as String : '',
          // Forwarded verbatim: the current contract is that this is `ansi`, and
          // passing it through (rather than assuming) keeps the app honest if the
          // agent ever reports otherwise. Absent means the current contract.
          format: data['format'] is String ? data['format'] as String : 'ansi',
        );
      case 'herdr_structure':
        _herdrSink?.applyStructure(data);
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

  Future<CodexPage<CodexProject>> codexProjects({String? cursor}) async {
    final reply = await _request(<String, dynamic>{
      'type': 'codex_projects',
      'cursor': ?cursor,
    });
    return CodexPage<CodexProject>(<CodexProject>[
      for (final item in (reply['projects'] as List<dynamic>? ?? <dynamic>[]))
        if (item is Json) CodexProject.fromJson(item),
    ], reply['nextCursor'] as String?);
  }

  Future<CodexPage<CodexThread>> codexThreads({
    String? projectId,
    String? cursor,
  }) async {
    final reply = await _request(<String, dynamic>{
      'type': 'codex_threads',
      'projectId': ?projectId,
      'cursor': ?cursor,
    });
    return CodexPage<CodexThread>(<CodexThread>[
      for (final item in (reply['threads'] as List<dynamic>? ?? <dynamic>[]))
        if (item is Json) CodexThread.fromJson(item),
    ], reply['nextCursor'] as String?);
  }

  Future<CodexTranscript> codexRead(String threadId, {String? cursor}) async {
    final reply = await _request(<String, dynamic>{
      'type': 'codex_read',
      'threadId': threadId,
      'cursor': ?cursor,
    });
    return CodexTranscript.fromJson(reply);
  }

  Future<void> codexResume(String threadId) =>
      _request(<String, dynamic>{'type': 'codex_resume', 'threadId': threadId});

  Future<void> codexSend(String threadId, String text, {String? turnId}) =>
      _request(<String, dynamic>{
        'type': 'codex_send',
        'threadId': threadId,
        'text': text,
        'turnId': ?turnId,
      });

  Future<void> codexInterrupt(String threadId, String turnId) =>
      _request(<String, dynamic>{
        'type': 'codex_interrupt',
        'threadId': threadId,
        'turnId': turnId,
      });

  Future<void> codexRespond(
    String threadId,
    String requestId,
    String decision, {
    Map<String, List<String>>? answers,
  }) => _request(<String, dynamic>{
    'type': 'codex_respond',
    'threadId': threadId,
    'requestId': requestId,
    'decision': decision,
    'answers': ?answers,
  });

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

  Future<SessionInfo> createTerminal({
    required String cwd,
    int? cols,
    int? rows,
  }) async {
    final reply = await _request(<String, dynamic>{
      'type': 'create_terminal',
      'cwd': cwd,
      'cols': ?cols,
      'rows': ?rows,
    });
    final info = SessionInfo.fromJson(reply['session'] as Json);
    _upsertSession(info);
    return info;
  }

  Future<void> terminalInput(String sessionId, String data) =>
      _request(<String, dynamic>{
        'type': 'terminal_input',
        'sessionId': sessionId,
        'data': data,
      });

  Future<void> terminalResize(String sessionId, int cols, int rows) =>
      _request(<String, dynamic>{
        'type': 'terminal_resize',
        'sessionId': sessionId,
        'cols': cols,
        'rows': rows,
      });

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
        _request(<String, dynamic>{
          'type': 'unsubscribe',
          'sessionId': id,
        }).then((_) {}, onError: (Object _) {}),
      );
    }
  }

  Future<void> send(String sessionId, String text) => _request(
    <String, dynamic>{'type': 'send', 'sessionId': sessionId, 'text': text},
  );

  Future<void> interrupt(String sessionId) =>
      _request(<String, dynamic>{'type': 'interrupt', 'sessionId': sessionId});

  /// [decision] is allow | allow_always | deny.
  Future<void> respondPermission(
    String sessionId,
    String requestId,
    String decision, {
    String? message,
    Map<String, String>? answers,
  }) => _request(<String, dynamic>{
    'type': 'permission',
    'sessionId': sessionId,
    'requestId': requestId,
    'decision': decision,
    if (message != null && message.trim().isNotEmpty) 'message': message,
    'answers': ?answers,
  });

  Future<void> setMode(String sessionId, String mode) => _request(
    <String, dynamic>{'type': 'set_mode', 'sessionId': sessionId, 'mode': mode},
  );

  // -------------------------------------------------------------------------
  // Herdr
  // -------------------------------------------------------------------------

  /// Re-probe availability; `force` bypasses the desktop agent's cache.
  Future<HerdrAvailability> herdrInfo({bool force = false}) async {
    final reply = await _request(<String, dynamic>{
      'type': 'herdr_info',
      'force': force,
    });
    return HerdrAvailability.fromJson(
      reply['availability'] as Json? ?? const <String, dynamic>{},
    );
  }

  Future<List<HerdrWorkspace>> herdrWorkspaces() async {
    final reply = await _request(<String, dynamic>{'type': 'herdr_workspaces'});
    return <HerdrWorkspace>[
      for (final raw in (reply['workspaces'] as List<dynamic>? ?? <dynamic>[]))
        if (raw is Json) HerdrWorkspace.fromJson(raw),
    ];
  }

  Future<List<HerdrTab>> herdrTabs(String workspaceId) async {
    final reply = await _request(<String, dynamic>{
      'type': 'herdr_tabs',
      'workspaceId': workspaceId,
    });
    return <HerdrTab>[
      for (final raw in (reply['tabs'] as List<dynamic>? ?? <dynamic>[]))
        if (raw is Json) HerdrTab.fromJson(raw),
    ];
  }

  Future<List<HerdrPane>> herdrPanes(String workspaceId) async {
    final reply = await _request(<String, dynamic>{
      'type': 'herdr_panes',
      'workspaceId': workspaceId,
    });
    return <HerdrPane>[
      for (final raw in (reply['panes'] as List<dynamic>? ?? <dynamic>[]))
        if (raw is Json) HerdrPane.fromJson(raw),
    ];
  }

  Future<List<HerdrAgent>> herdrAgents() async {
    final reply = await _request(<String, dynamic>{'type': 'herdr_agents'});
    return <HerdrAgent>[
      for (final raw in (reply['agents'] as List<dynamic>? ?? <dynamic>[]))
        if (raw is Json) HerdrAgent.fromJson(raw),
    ];
  }

  Future<HerdrAgent> herdrAgent(String target) async {
    final reply = await _request(<String, dynamic>{
      'type': 'herdr_agent',
      'target': target,
    });
    return HerdrAgent.fromJson(
      reply['agent'] as Json? ?? const <String, dynamic>{},
    );
  }

  Future<HerdrLayout> herdrLayout(String paneId) async {
    final reply = await _request(<String, dynamic>{
      'type': 'herdr_layout',
      'paneId': paneId,
    });
    return HerdrLayout.fromJson(
      reply['layout'] as Json? ?? const <String, dynamic>{},
    );
  }

  Future<HerdrOutput> herdrRead(
    String paneId, {
    HerdrReadSource source = HerdrReadSource.visible,
    int lines = 200,
  }) async {
    final reply = await _request(<String, dynamic>{
      'type': 'herdr_read',
      'paneId': paneId,
      'source': source.wire,
      'lines': lines,
    });
    return HerdrOutput.fromJson(reply);
  }

  /// Submit a task to an agent. Never retried by the caller: a stalled result
  /// must be inspected on the desktop, not blindly resent.
  Future<HerdrActionReport> herdrPrompt(
    String target,
    String text, {
    bool wait = false,
    int? timeoutMs,
  }) => _request(<String, dynamic>{
    'type': 'herdr_prompt',
    'target': target,
    'text': text,
    'wait': wait,
    'timeoutMs': ?timeoutMs,
  }).then(HerdrActionReport.fromJson);

  Future<HerdrActionReport> herdrSendText(
    String paneId,
    String text, {
    bool paste = false,
  }) {
    // Older agents ignore unknown request fields. Refuse an unrecognised paste
    // rather than letting the clipboard become raw terminal keystrokes.
    if (paste && !_herdrPasteReady) {
      return Future<HerdrActionReport>.error(
        const RemoteException('当前电脑版不支持终端粘贴，请更新电脑版后重新连接'),
      );
    }
    return _request(<String, dynamic>{
      'type': 'herdr_send_text',
      'paneId': paneId,
      'text': text,
      if (paste) 'paste': true,
    }).then(HerdrActionReport.fromJson);
  }

  Future<HerdrActionReport> herdrSendKeys(
    String target,
    List<String> keys, {
    int? repeat,
  }) => _request(<String, dynamic>{
    'type': 'herdr_send_keys',
    'target': target,
    'keys': keys,
    'repeat': ?repeat,
  }).then(HerdrActionReport.fromJson);

  Future<HerdrActionReport> herdrRun(String paneId, String command) =>
      _request(<String, dynamic>{
        'type': 'herdr_run',
        'paneId': paneId,
        'command': command,
      }).then(HerdrActionReport.fromJson);

  Future<HerdrActionReport> herdrAct(Json action) => _request(<String, dynamic>{
    'type': 'herdr_act',
    'action': action,
  }).then(HerdrActionReport.fromJson);

  /// Selects the pane whose live output the agent should push, or clears it.
  Future<void> herdrWatch(String? paneId) async {
    await _request(<String, dynamic>{'type': 'herdr_watch', 'paneId': paneId});
  }

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
    if (phase != ConnectionPhase.online) {
      _infoEpoch += 1;
      _herdrPasteReady = false;
    }
    _phase = phase;
    _notify();
  }

  void _teardownSocket() {
    _infoEpoch += 1;
    _herdrPasteReady = false;
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
    unawaited(_codexNotices.close());
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
