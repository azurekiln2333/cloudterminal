// Cross-language check: the real Node relay + AgentCore (with a scripted
// Claude, see server/scripts/demo-agent.ts) driven by the real
// RemoteController over a real WebSocket. Skipped when server/ deps are
// not installed.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cloudterminal/models/protocol.dart';
import 'package:cloudterminal/state/app_store.dart';
import 'package:cloudterminal/state/remote_controller.dart';
import 'package:cloudterminal/state/session_view.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

final bool _serverReady =
    Directory('server/node_modules/ws').existsSync();

Future<T> _waitFor<T>(
  Listenable listenable,
  T? Function() probe, {
  Duration timeout = const Duration(seconds: 15),
}) {
  final now = probe();
  if (now != null) return Future<T>.value(now);
  final completer = Completer<T>();
  void check() {
    final v = probe();
    if (v != null && !completer.isCompleted) completer.complete(v);
  }

  listenable.addListener(check);
  return completer.future
      .timeout(timeout)
      .whenComplete(() => listenable.removeListener(check));
}

void main() {
  Process? agent;
  late String pairCode;
  late String root;
  const port = 8791;

  setUpAll(() async {
    if (!_serverReady) return;
    agent = await Process.start(
      'node',
      <String>['scripts/demo-agent.ts', '--port', '$port', '--fast'],
      workingDirectory: 'server',
    );
    final ready = Completer<void>();
    agent!.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      final m = RegExp(r'DEMO READY .*pairCode=(\S+) root=(.+)$').firstMatch(line);
      if (m != null && !ready.isCompleted) {
        pairCode = m.group(1)!;
        root = m.group(2)!.trim();
        ready.complete();
      }
    });
    agent!.stderr.transform(utf8.decoder).listen(stderr.write);
    await ready.future.timeout(const Duration(seconds: 20));
  });

  tearDownAll(() {
    agent?.kill();
  });

  test('pairs, runs a turn, answers a permission and a question', () async {
    final controller = RemoteController(store: AppStore.memory());
    addTearDown(controller.dispose);

    await controller.pairWithCode('127.0.0.1:$port', pairCode);
    await _waitFor(controller, () => controller.agent);
    expect(controller.phase, ConnectionPhase.online);
    expect(controller.agentName, 'demo-pc');

    final session = await controller.createSession(cwd: root, prompt: '修一下 main.dart');
    final SessionView view = controller.view(session);
    await controller.subscribe(session.id);

    // 1. Bash permission → allow.
    var request = await _waitFor(view, () => view.pendingPermissions.firstOrNull);
    expect(request.toolName, 'Bash');
    expect(view.events.whereType<UserEvent>().single.text, '修一下 main.dart');
    await controller.respondPermission(session.id, request.requestId, 'allow');

    // 2. Edit permission → allow always.
    request = await _waitFor(view, () {
      final p = view.pendingPermissions.firstOrNull;
      return p?.toolName == 'Edit' ? p : null;
    });
    expect(request.canAlwaysAllow, isTrue);
    await controller.respondPermission(session.id, request.requestId, 'allow_always');

    // 3. AskUserQuestion → answer.
    request = await _waitFor(view, () {
      final p = view.pendingPermissions.firstOrNull;
      return p != null && p.isQuestion ? p : null;
    });
    await controller.respondPermission(
      session.id,
      request.requestId,
      'allow',
      answers: <String, String>{request.questions!.first.question: '要'},
    );

    final result = await _waitFor(view, () => view.events.whereType<ResultEvent>().firstOrNull);
    expect(result.isError, isFalse);
    expect(view.events.whereType<ToolResultEvent>().length, 2);
    expect(
      view.events.whereType<AssistantEvent>().map((e) => e.text),
      contains(contains('要')),
    );
    await _waitFor(controller, () => controller.session(session.id)?.status == SessionStatus.idle ? true : null);
    expect(controller.session(session.id)!.costUsd, greaterThan(0));

    // Wrong secret is rejected by the relay.
    final bad = RemoteController(store: AppStore.memory());
    addTearDown(bad.dispose);
    await bad.pairManually('127.0.0.1:$port', 'demo-agent-0001', 'wrong');
    await _waitFor(bad, () => bad.phase == ConnectionPhase.authFailed ? true : null);
  }, skip: _serverReady ? false : 'run `npm install` in server/ first');
}
