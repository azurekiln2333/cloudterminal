import 'dart:async';

import 'package:cloudterminal/models/protocol.dart';
import 'package:cloudterminal/net/relay_socket.dart';
import 'package:cloudterminal/state/app_store.dart';
import 'package:cloudterminal/state/remote_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_relay.dart';

const Pairing kPairing = Pairing(
  relayUrl: 'wss://relay.example.com/ws',
  agentId: 'a_test',
  secret: 'shh',
);

Future<void> settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('RemoteController', () {
    late List<FakeSocket> sockets;
    late List<FakeSocket> queue;
    late RemoteController controller;

    RemoteController build({Pairing? pairing = kPairing}) {
      final store = AppStore.memory();
      if (pairing != null) unawaited(store.setPairing(pairing));
      return RemoteController(
        store: store,
        connector: (Uri url) async {
          final socket = queue.isNotEmpty ? queue.removeAt(0) : healthyAgent();
          sockets.add(socket);
          return socket;
        },
      );
    }

    setUp(() {
      sockets = <FakeSocket>[];
      queue = <FakeSocket>[];
    });

    tearDown(() => controller.dispose());

    test('starts unpaired without a saved pairing', () {
      controller = build(pairing: null);
      expect(controller.phase, ConnectionPhase.unpaired);
    });

    test('authenticates, loads info and sessions', () async {
      queue.add(healthyAgent(sessions: <Map<String, dynamic>>[
        sessionJson('s1', updatedAt: 10),
        sessionJson('s2', updatedAt: 5, pending: 1, status: 'waiting'),
      ]));
      controller = build()..connect();
      await settle();

      final hello = sockets.single.sent.first;
      expect(hello, <String, dynamic>{
        't': 'hello',
        'role': 'client',
        'agentId': 'a_test',
        'secret': 'shh',
        'v': 1,
      });
      expect(controller.phase, ConnectionPhase.online);
      expect(controller.agent?.host, 'DESKTOP');
      expect(controller.agentName, 'DESKTOP');
      // Sessions waiting for approval sort first.
      expect(controller.sessions.map((s) => s.id), <String>['s2', 's1']);
      expect(controller.pendingTotal, 1);
    });

    test('streams events, deltas and permissions into the session view', () async {
      queue.add(healthyAgent(
        sessions: <Map<String, dynamic>>[sessionJson('s1', status: 'running')],
        backlog: <String, List<Map<String, dynamic>>>{
          's1': <Map<String, dynamic>>[
            <String, dynamic>{'kind': 'user', 'text': 'run tests', 'seq': 1, 'ts': 1},
          ],
        },
      ));
      controller = build()..connect();
      await settle();

      final view = controller.view(controller.session('s1')!);
      await controller.subscribe('s1');
      expect(view.events.single, isA<UserEvent>());
      final socket = sockets.single;

      socket.msg(<String, dynamic>{'kind': 'delta', 'sessionId': 's1', 'text': 'Work'});
      socket.msg(<String, dynamic>{'kind': 'delta', 'sessionId': 's1', 'text': 'ing'});
      await settle();
      expect(view.streaming, 'Working');

      socket.msg(<String, dynamic>{
        'kind': 'event',
        'sessionId': 's1',
        'event': <String, dynamic>{'kind': 'assistant', 'text': 'Working on it', 'seq': 2, 'ts': 2},
      });
      socket.msg(<String, dynamic>{
        'kind': 'event',
        'sessionId': 's1',
        'event': <String, dynamic>{
          'kind': 'permission_request',
          'requestId': 'p1',
          'toolName': 'Bash',
          'title': 'Run npm test?',
          'input': <String, dynamic>{'command': 'npm test'},
          'canAlwaysAllow': true,
          'seq': 3,
          'ts': 3,
        },
      });
      await settle();
      expect(view.streaming, isEmpty);
      expect(view.pendingPermissions.single.requestId, 'p1');

      await controller.respondPermission('s1', 'p1', 'allow_always');
      expect(socket.lastRequest('permission'), containsPair('decision', 'allow_always'));

      socket.msg(<String, dynamic>{
        'kind': 'event',
        'sessionId': 's1',
        'event': <String, dynamic>{'kind': 'permission_resolved', 'requestId': 'p1', 'decision': 'allow_always', 'seq': 4, 'ts': 4},
      });
      // Duplicate delivery (resubscribe race) is ignored.
      socket.msg(<String, dynamic>{
        'kind': 'event',
        'sessionId': 's1',
        'event': <String, dynamic>{'kind': 'assistant', 'text': 'dup', 'seq': 2, 'ts': 2},
      });
      await settle();
      expect(view.pendingPermissions, isEmpty);
      expect(view.events.length, 4);
    });

    test('resubscribes from the last seq after reconnecting', () async {
      final first = healthyAgent(
        sessions: <Map<String, dynamic>>[sessionJson('s1')],
        backlog: <String, List<Map<String, dynamic>>>{
          's1': <Map<String, dynamic>>[
            <String, dynamic>{'kind': 'user', 'text': 'hi', 'seq': 1, 'ts': 1},
            <String, dynamic>{'kind': 'assistant', 'text': 'hello', 'seq': 2, 'ts': 2},
          ],
        },
      );
      final second = healthyAgent(sessions: <Map<String, dynamic>>[sessionJson('s1')]);
      queue.addAll(<FakeSocket>[first, second]);
      controller = build()..connect();
      await settle();
      controller.view(controller.session('s1')!);
      await controller.subscribe('s1');

      first.drop();
      await settle();
      expect(controller.phase, ConnectionPhase.disconnected);
      controller.reconnectNow();
      await settle();

      expect(controller.phase, ConnectionPhase.online);
      expect(second.lastRequest('subscribe'), containsPair('afterSeq', 2));
    });

    test('stops retrying and reports authFailed on unauthorized', () async {
      final bad = FakeSocket();
      bad.onSend = (s, f) => scheduleMicrotask(() {
            s.push(<String, dynamic>{'t': 'error', 'code': 'unauthorized', 'message': 'nope'});
            s.drop();
          });
      queue.add(bad);
      controller = build()..connect();
      await settle();
      expect(controller.phase, ConnectionPhase.authFailed);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(sockets.length, 1);
    });

    test('fails in-flight requests when the PC goes offline', () async {
      final socket = healthyAgent();
      queue.add(socket);
      controller = build()..connect();
      await settle();
      socket.onSend = (_, _) {}; // agent stops answering
      final pending = controller.refreshSessions();
      socket.push(<String, dynamic>{'t': 'presence', 'online': false});
      await expectLater(pending, throwsA(isA<RemoteException>()));
      expect(controller.phase, ConnectionPhase.agentOffline);
      await expectLater(controller.send('s1', 'hi'), throwsA(isA<RemoteException>()));
    });

    test('surfaces agent errors as RemoteException', () async {
      final socket = healthyAgent();
      queue.add(socket);
      controller = build()..connect();
      await settle();
      socket.onSend = (s, f) => scheduleMicrotask(() => s.msg(<String, dynamic>{
            'kind': 'error',
            'id': (f['data'] as Map<String, dynamic>)['id'],
            'message': '路径不在允许的目录内',
          }));
      await expectLater(
        controller.createSession(cwd: '/etc'),
        throwsA(isA<RemoteException>().having((e) => e.message, 'message', '路径不在允许的目录内')),
      );
    });

    test('pairs with a one-time code', () async {
      final pairSocket = FakeSocket();
      pairSocket.onSend = (s, f) {
        expect(f, <String, dynamic>{'t': 'hello', 'role': 'pair', 'code': 'ABCD-2345'});
        scheduleMicrotask(() => s.push(<String, dynamic>{
              't': 'paired',
              'agentId': 'a_new',
              'secret': 'fresh',
              'name': 'Laptop',
            }));
      };
      queue.addAll(<FakeSocket>[pairSocket, healthyAgent()]);
      controller = build(pairing: null);
      await controller.pairWithCode('relay.example.com', 'ABCD-2345');
      await settle();
      expect(controller.pairing?.agentId, 'a_new');
      expect(controller.pairing?.relayUrl, 'wss://relay.example.com/ws');
      expect(controller.phase, ConnectionPhase.online);
    });

    test('explains a rejected pairing code', () async {
      final pairSocket = FakeSocket();
      pairSocket.onSend = (s, f) => scheduleMicrotask(
            () => s.push(<String, dynamic>{'t': 'error', 'code': 'unauthorized', 'message': 'x'}),
          );
      queue.add(pairSocket);
      controller = build(pairing: null);
      await expectLater(
        controller.pairWithCode('relay.example.com', 'ZZZZ-2222'),
        throwsA(isA<RemoteException>().having((e) => e.message, 'message', contains('配对码无效'))),
      );
      expect(controller.phase, ConnectionPhase.unpaired);
    });
  });

  group('normalizeRelayUrl', () {
    test('adds scheme and /ws path', () {
      expect(normalizeRelayUrl('relay.example.com').toString(), 'wss://relay.example.com/ws');
      expect(normalizeRelayUrl('https://relay.example.com/').toString(), 'wss://relay.example.com/ws');
      expect(normalizeRelayUrl('http://relay.example.com:8080').toString(), 'ws://relay.example.com:8080/ws');
    });

    test('uses ws:// for LAN hosts', () {
      expect(normalizeRelayUrl('192.168.1.5:8787').toString(), 'ws://192.168.1.5:8787/ws');
      expect(normalizeRelayUrl('localhost:8787').toString(), 'ws://localhost:8787/ws');
    });

    test('keeps custom paths and drops queries', () {
      expect(normalizeRelayUrl('wss://x.com/relay/ws?a=1').toString(), 'wss://x.com/relay/ws');
    });

    test('rejects garbage', () {
      expect(normalizeRelayUrl(''), isNull);
      expect(normalizeRelayUrl('ftp://x.com'), isNull);
    });
  });

  group('SessionEvent.fromJson', () {
    test('parses questions and unknown kinds', () {
      final e = SessionEvent.fromJson(<String, dynamic>{
        'kind': 'permission_request',
        'requestId': 'r',
        'toolName': 'AskUserQuestion',
        'title': 'Q',
        'input': null,
        'canAlwaysAllow': false,
        'questions': <dynamic>[
          <String, dynamic>{
            'question': 'Which?',
            'options': <dynamic>[
              <String, dynamic>{'label': 'A'},
              <String, dynamic>{'label': 'B', 'description': 'b'},
            ],
          },
        ],
        'seq': 1,
        'ts': 0,
      });
      expect(e, isA<PermissionRequestEvent>());
      final p = e as PermissionRequestEvent;
      expect(p.isQuestion, isTrue);
      expect(p.questions!.single.options[1].description, 'b');

      expect(SessionEvent.fromJson(<String, dynamic>{'kind': 'future', 'seq': 2}), isA<UnknownEvent>());
    });
  });
}
