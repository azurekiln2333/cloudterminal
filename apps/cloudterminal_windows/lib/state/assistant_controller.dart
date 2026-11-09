import 'dart:async';

import 'package:flutter/foundation.dart';

import '../engine/sidecar_client.dart';
import '../models/tool.dart';

/// Owns all assistant state and the sidecar connection.
///
/// Nothing here fabricates data: the snapshot, probes and stream events come
/// from the sidecar. When the sidecar is not running the UI shows why instead
/// of inventing tools or sessions.
class AssistantController extends ChangeNotifier {
  AssistantController({required this.sidecar});

  final SidecarClient sidecar;
  StreamSubscription<Map<String, dynamic>>? _sub;

  bool _starting = false;
  bool _running = false;
  String? _fatalError;
  AssistantSnapshot _snapshot = const AssistantSnapshot(relayOnline: false);
  PairCodeInfo? _pairCode;
  final Map<String, List<ToolEvent>> _streams = <String, List<ToolEvent>>{};
  final Set<String> _activeSession = <String>{};
  int _lastSeq = 0;

  bool get starting => _starting;
  bool get running => _running;
  String? get fatalError => _fatalError;
  AssistantSnapshot get snapshot => _snapshot;
  PairCodeInfo? get pairCode => _pairCode;

  List<ToolEvent> events(String sessionId) =>
      _streams[sessionId] ?? const <ToolEvent>[];

  bool isActive(String sessionId) => _activeSession.contains(sessionId);
  int get lastSeq => _lastSeq;

  Future<void> start() async {
    if (_starting || _running) return;
    _starting = true;
    _fatalError = null;
    notifyListeners();
    try {
      _sub = sidecar.messages.listen(_onMessage);
      await sidecar.start();
      _running = true;
      sidecar.probeTools();
      sidecar.requestPairCode();
    } catch (e) {
      _fatalError = _friendly(e);
    } finally {
      _starting = false;
      notifyListeners();
    }
  }

  void _onMessage(Map<String, dynamic> message) {
    switch (message['type']) {
      case 'snapshot':
        _snapshot = AssistantSnapshot.fromJson(message);
        _lastSeq = message['seq'] is num ? (message['seq'] as num).toInt() : _lastSeq;
        notifyListeners();
      case 'pair_code':
        _pairCode = PairCodeInfo.fromJson(message);
        notifyListeners();
      case 'stream_event':
        _onStreamEvent(message);
      case '_stderr':
        // Sidecar diagnostics are surfaced only as a status line, never as UI
        // content the user could mistake for a session.
        break;
      case '_error':
        _fatalError = message['text'] as String?;
        notifyListeners();
      default:
        break;
    }
  }

  void _onStreamEvent(Map<String, dynamic> message) {
    final event = ToolEvent.fromJson(message);
    if (event.sessionId.isEmpty) return;
    if (event.isSnapshot) {
      // A poll or history refresh replaces the buffer; it is NOT an append,
      // which is why the origin label on the binding matters.
      _streams[event.sessionId] = <ToolEvent>[event];
    } else {
      final list = _streams.putIfAbsent(event.sessionId, () => <ToolEvent>[]);
      list.add(event);
      // Bound the buffer so sustained output cannot grow without limit.
      const maxLines = 5000;
      if (list.length > maxLines) {
        list.removeRange(0, list.length - maxLines);
      }
    }
    notifyListeners();
  }

  Future<void> requestPairCode() async {
    sidecar.requestPairCode();
  }

  Future<void> resetPairing() async {
    sidecar.resetPairing();
    _pairCode = null;
    notifyListeners();
  }

  void refreshTools() => sidecar.probeTools();

  /// Configure the relay from the UI. After this the sidecar reconnects, so the
  /// next snapshot reflects the new state.
  void setRelay({String? url, String? key, bool clear = false}) =>
      sidecar.setRelay(url: url, key: key, clear: clear);

  void bind(SessionBinding binding) {
    _activeSession.add(binding.id);
    sidecar.bindSession(binding.id);
    notifyListeners();
  }

  void unbind(SessionBinding binding) {
    _activeSession.remove(binding.id);
    sidecar.unbindSession(binding.id);
    notifyListeners();
  }

  void sendInput(String sessionId, String text) =>
      sidecar.sendInput(sessionId, text);

  void setPollInterval(String sessionId, int milliseconds) =>
      sidecar.setPollInterval(sessionId, milliseconds);

  /// Start a new managed Claude stream; the binding appears in the next snapshot.
  void startManagedClaude({String? prompt}) =>
      sidecar.startManagedClaude(prompt: prompt);

  String _friendly(Object error) {
    final text = error.toString();
    if (text.contains('ProcessException') || text.contains('system cannot find')) {
      return '找不到后台服务或 Node.js。请确认已安装 Node.js 24 LTS，'
          '并且 server/ 依赖已安装（npm ci）。';
    }
    return text;
  }

  @override
  void dispose() {
    _sub?.cancel();
    unawaited(sidecar.dispose());
    super.dispose();
  }
}
