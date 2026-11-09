import 'dart:async';

import 'package:cloudterminal/net/relay_socket.dart';

/// In-memory stand-in for the relay: records what the app sends and lets
/// the test push frames back.
class FakeSocket implements RelaySocket {
  final StreamController<Map<String, dynamic>> _in =
      StreamController<Map<String, dynamic>>.broadcast();
  final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];
  bool closed = false;

  /// Called for every frame the app sends; use it to script replies.
  void Function(FakeSocket socket, Map<String, dynamic> frame)? onSend;

  @override
  Stream<Map<String, dynamic>> get frames => _in.stream;

  @override
  void send(Map<String, dynamic> frame) {
    sent.add(frame);
    onSend?.call(this, frame);
  }

  void push(Map<String, dynamic> frame) {
    if (!_in.isClosed) _in.add(frame);
  }

  /// Agent → app message.
  void msg(Map<String, dynamic> data) =>
      push(<String, dynamic>{'t': 'msg', 'data': data});

  /// Messages (the `data` of msg frames) the app sent.
  List<Map<String, dynamic>> get requests => <Map<String, dynamic>>[
    for (final f in sent)
      if (f['t'] == 'msg') f['data'] as Map<String, dynamic>,
  ];

  Map<String, dynamic>? lastRequest(String type) {
    for (final r in requests.reversed) {
      if (r['type'] == type) return r;
    }
    return null;
  }

  void drop() {
    closed = true;
    unawaited(_in.close());
  }

  @override
  Future<void> close() async => drop();

  @override
  int? get closeCode => closed ? 1000 : null;

  @override
  String? get closeReason => null;
}

Map<String, dynamic> sessionJson(
  String id, {
  String status = 'idle',
  int pending = 0,
  String title = 'Fix tests',
  int updatedAt = 1000,
  String mode = 'default',
  String kind = 'claude',
}) => <String, dynamic>{
  'id': id,
  'kind': kind,
  'title': title,
  'cwd': r'C:\work\app',
  'status': status,
  'mode': mode,
  'createdAt': 1,
  'updatedAt': updatedAt,
  'costUsd': 0.12,
  'pending': pending,
  'lastSeq': 0,
};

/// A socket that behaves like a healthy agent: accepts hello, answers
/// info / list_sessions / subscribe / everything else with ack.
FakeSocket healthyAgent({
  Map<String, dynamic>? codex,
  List<String> capabilities = const <String>[],
  List<Map<String, dynamic>> sessions = const <Map<String, dynamic>>[],
  Map<String, List<Map<String, dynamic>>> backlog =
      const <String, List<Map<String, dynamic>>>{},
}) {
  final socket = FakeSocket();
  socket.onSend = (s, frame) {
    if (frame['t'] == 'hello') {
      scheduleMicrotask(
        () => s.push(<String, dynamic>{
          't': 'hello_ok',
          'clientId': 'c1',
          'online': true,
          'name': 'DESKTOP',
        }),
      );
      return;
    }
    final data = frame['data'] as Map<String, dynamic>;
    final id = data['id'];
    scheduleMicrotask(() {
      switch (data['type']) {
        case 'info':
          s.msg(<String, dynamic>{
            'kind': 'info',
            'id': id,
            'host': 'DESKTOP',
            'platform': 'win32',
            'defaultCwd': r'C:\work',
            'roots': <String>[r'C:\work'],
            'allowBypass': false,
            'capabilities': capabilities,
            'codex': ?codex,
          });
        case 'list_sessions':
          s.msg(<String, dynamic>{
            'kind': 'sessions',
            'id': id,
            'sessions': sessions,
          });
        case 'create_terminal':
          s.msg(<String, dynamic>{
            'kind': 'session_created',
            'id': id,
            'session': <String, dynamic>{
              ...sessionJson('t1', kind: 'terminal'),
              'cwd': data['cwd'],
              'cols': data['cols'] ?? 80,
              'rows': data['rows'] ?? 24,
            },
          });
        case 'subscribe':
          s.msg(<String, dynamic>{
            'kind': 'events',
            'id': id,
            'sessionId': data['sessionId'],
            'events': backlog[data['sessionId']] ?? <Map<String, dynamic>>[],
            'reset': data['afterSeq'] == 0,
          });
        default:
          s.msg(<String, dynamic>{'kind': 'ack', 'id': id});
      }
    });
  };
  return socket;
}
