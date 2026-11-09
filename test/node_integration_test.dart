// Cross-language check: the real Node relay + AgentCore (with a scripted
// Claude, see server/scripts/demo-agent.ts) driven by the real
// RemoteController over a real WebSocket. Skipped when server/ deps are
// not installed.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cloudterminal/models/herdr.dart';
import 'package:cloudterminal/models/protocol.dart';
import 'package:cloudterminal/state/app_store.dart';
import 'package:cloudterminal/state/remote_controller.dart';
import 'package:cloudterminal/state/session_view.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

final bool _serverReady = Directory('server/node_modules/ws').existsSync();

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
    agent = await Process.start('node', <String>[
      'scripts/demo-agent.ts',
      '--port',
      '$port',
      '--fast',
    ], workingDirectory: 'server');
    final ready = Completer<void>();
    agent!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          final m = RegExp(
            r'DEMO READY .*pairCode=(\S+) root=(.+)$',
          ).firstMatch(line);
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

  test(
    'pairs, runs a turn, answers a permission and a question',
    () async {
      final controller = RemoteController(store: AppStore.memory());
      addTearDown(controller.dispose);

      await controller.pairWithCode('127.0.0.1:$port', pairCode);
      await _waitFor(controller, () => controller.agent);
      expect(controller.phase, ConnectionPhase.online);
      expect(controller.agentName, 'demo-pc');

      final session = await controller.createSession(
        cwd: root,
        prompt: '修一下 main.dart',
      );
      final SessionView view = controller.view(session);
      await controller.subscribe(session.id);

      // 1. Bash permission → allow.
      var request = await _waitFor(
        view,
        () => view.pendingPermissions.firstOrNull,
      );
      expect(request.toolName, 'Bash');
      expect(view.events.whereType<UserEvent>().single.text, '修一下 main.dart');
      await controller.respondPermission(
        session.id,
        request.requestId,
        'allow',
      );

      // 2. Edit permission → allow always.
      request = await _waitFor(view, () {
        final p = view.pendingPermissions.firstOrNull;
        return p?.toolName == 'Edit' ? p : null;
      });
      expect(request.canAlwaysAllow, isTrue);
      await controller.respondPermission(
        session.id,
        request.requestId,
        'allow_always',
      );

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

      final result = await _waitFor(
        view,
        () => view.events.whereType<ResultEvent>().firstOrNull,
      );
      expect(result.isError, isFalse);
      expect(view.events.whereType<ToolResultEvent>().length, 2);
      expect(
        view.events.whereType<AssistantEvent>().map((e) => e.text),
        contains(contains('要')),
      );
      await _waitFor(
        controller,
        () => controller.session(session.id)?.status == SessionStatus.idle
            ? true
            : null,
      );
      expect(controller.session(session.id)!.costUsd, greaterThan(0));

      // A real desktop PTY, exercised through Dart -> relay -> agent.
      expect(controller.agent!.capabilities, contains('terminal'));
      final terminal = await controller.createTerminal(
        cwd: root,
        cols: 80,
        rows: 24,
      );
      expect(terminal.isTerminal, isTrue);
      final terminalView = controller.view(terminal);
      await controller.subscribe(terminal.id);
      await controller.terminalInput(
        terminal.id,
        Platform.isWindows
            ? 'echo MOBILE_PTY_O^K\r'
            : "printf 'MOBILE_PTY_%s\\n' OK\r",
      );
      await _waitFor(
        terminalView,
        () => terminalView.terminal.buffer.getText().contains('MOBILE_PTY_OK')
            ? true
            : null,
      );
      await controller.terminalResize(terminal.id, 100, 30);
      await _waitFor(
        controller,
        () => controller.session(terminal.id)?.cols == 100 ? true : null,
      );
      controller.unsubscribe(terminal.id);
      final seq = terminalView.lastSeq;
      await controller.terminalInput(
        terminal.id,
        Platform.isWindows
            ? 'echo REPLAY_PTY_O^K\r'
            : "printf 'REPLAY_PTY_%s\\n' OK\r",
      );
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await controller.subscribe(terminal.id);
      await _waitFor(
        terminalView,
        () => terminalView.terminal.buffer.getText().contains('REPLAY_PTY_OK')
            ? true
            : null,
      );
      expect(terminalView.lastSeq, greaterThan(seq));
      await controller.terminalInput(terminal.id, 'exit\r');
      await _waitFor(
        controller,
        () => controller.session(terminal.id)?.isClosed == true ? true : null,
      );
      await controller.closeSession(terminal.id);

      // Wrong secret is rejected by the relay.
      final bad = RemoteController(store: AppStore.memory());
      addTearDown(bad.dispose);
      await bad.pairManually('127.0.0.1:$port', controller.pairing!.agentId, 'wrong');
      await _waitFor(
        bad,
        () => bad.phase == ConnectionPhase.authFailed ? true : null,
      );
    },
    skip: _serverReady ? false : 'run `npm install` in server/ first',
  );

  test(
    'herdr capability flows from the Node agent to the Dart client',
    () async {
      if (!_serverReady) return;
      // A demo agent with a scripted Herdr runner: no Herdr install, no real
      // workspace touched. This exercises the real Node<->Dart wire shapes.
      const herdrPort = 8792;
      final herdrAgent = await Process.start('node', <String>[
        'scripts/demo-agent.ts',
        '--port',
        '$herdrPort',
        '--fast',
        '--herdr',
      ], workingDirectory: 'server');
      addTearDown(herdrAgent.kill);
      final ready = Completer<String>();
      herdrAgent.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            final m = RegExp(
              r'DEMO READY .*pairCode=(\S+)',
            ).firstMatch(line);
            if (m != null && !ready.isCompleted) ready.complete(m.group(1)!);
          });
      herdrAgent.stderr.transform(utf8.decoder).listen(stderr.write);
      final code = await ready.future.timeout(const Duration(seconds: 20));

      final controller = RemoteController(store: AppStore.memory());
      addTearDown(controller.dispose);
      await controller.pairWithCode('127.0.0.1:$herdrPort', code);
      await _waitFor(controller, () => controller.agent);

      // 1. The agent advertises the capability and availability.
      expect(controller.agent!.capabilities, contains('herdr'));
      final availability = await controller.herdrInfo();
      expect(availability.available, isTrue);
      expect(availability.version, '0.9.3');
      expect(availability.protocol, 22);

      // 2. Real listing shapes parse into the typed Dart models.
      final workspaces = await controller.herdrWorkspaces();
      expect(workspaces, hasLength(1));
      expect(workspaces.single.workspaceId, 'wJ');
      expect(workspaces.single.label, 'cloudterminal');
      expect(workspaces.single.agentStatus, HerdrAgentStatus.working);
      expect(workspaces.single.activeTabId, 'wJ:t1');

      final agents = await controller.herdrAgents();
      expect(agents, hasLength(1));
      expect(agents.single.agentKind, 'pi');
      expect(agents.single.status, HerdrAgentStatus.idle);
      expect(agents.single.target, 'wJ:p2');

      final panes = await controller.herdrPanes('wJ');
      expect(panes, hasLength(1));
      expect(panes.single.paneId, 'wJ:p2');
      expect(panes.single.cwd, isNotEmpty);

      // 3. Raw pane text arrives as data, not a fabricated sample.
      final output = await controller.herdrRead(
        'wJ:p2',
        source: HerdrReadSource.recentUnwrapped,
        lines: 40,
      );
      expect(output.text, contains('DEMO_HERDR_PANE_OUTPUT'));

      // 4. A mutating action round-trips and returns a summary.
      final report = await controller.herdrAct(
        HerdrActions.paneSplit('wJ:p2', 'right', focus: false),
      );
      expect(report.summary, isNotEmpty);

      // 5. A prompt to the agent round-trips.
      final prompt = await controller.herdrPrompt('wJ:p2', 'run the tests');
      expect(prompt.summary, isNotEmpty);

      // 6. An unknown pane id is a typed error, not a silent success.
      await expectLater(
        controller.herdrRead('wZ:p9'),
        throwsA(
          isA<RemoteException>().having(
            (e) => e.message,
            'message',
            contains('pane_not_found'),
          ),
        ),
      );
    },
    skip: _serverReady ? false : 'run `npm install` in server/ first',
  );
}
