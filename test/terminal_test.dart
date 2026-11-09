import 'dart:convert';

import 'package:cloudterminal/models/protocol.dart';
import 'package:cloudterminal/state/app_store.dart';
import 'package:cloudterminal/state/remote_controller.dart';
import 'package:cloudterminal/state/session_view.dart';
import 'package:cloudterminal/screens/session_screen.dart';
import 'package:cloudterminal/widgets/new_session_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

import 'support/fake_relay.dart';

TerminalOutputEvent output(int seq, String data) =>
    TerminalOutputEvent(seq, DateTime(2026), data);

Future<RemoteController> controllerFor(FakeSocket socket) async {
  final store = AppStore.memory();
  await store.setPairing(
    const Pairing(relayUrl: 'wss://r/ws', agentId: 'a', secret: 's'),
  );
  return RemoteController(store: store, connector: (_) async => socket)
    ..connect();
}

void main() {
  test(
    'legacy protocol defaults to Claude and terminal output parses exactly',
    () {
      final legacy = sessionJson('old')..remove('kind');
      expect(SessionInfo.fromJson(legacy).isTerminal, isFalse);
      expect(AgentInfo.fromJson(<String, dynamic>{}).capabilities, isEmpty);
      final e = SessionEvent.fromJson(<String, dynamic>{
        'kind': 'terminal_output',
        'seq': 1,
        'data': '\x1b[31mred\x1b[0m\r\n',
      });
      expect((e as TerminalOutputEvent).data, '\x1b[31mred\x1b[0m\r\n');
    },
  );

  test(
    'terminal applies ANSI once, resets parser, suppresses backlog replies, bounds memory',
    () {
      final view = SessionView(
        SessionInfo.fromJson(sessionJson('t', kind: 'terminal')),
      );
      final replies = <String>[];
      view.onTerminalInput = replies.add;
      view.applyBacklog(<SessionEvent>[
        output(1, 'old\rNEW\x1b[6n'),
      ], reset: true);
      expect(view.terminal.buffer.getText(), startsWith('NEW'));
      expect(replies, isEmpty);
      view.applyEvent(output(2, '!'));
      view.applyBacklog(<SessionEvent>[output(2, '!')], reset: false);
      expect(view.terminal.buffer.getText(), startsWith('NEW!'));
      final old = view.terminal;
      view.applyBacklog(<SessionEvent>[
        output(100, '\x1b[?1049hALT'),
      ], reset: true);
      expect(identical(old, view.terminal), isFalse);
      expect(view.terminal.buffer.getText(), startsWith('ALT'));
      view.applyEvent(output(101, '\x1b[?1049lMAIN\x1b[6n'));
      expect(view.terminal.buffer.getText(), startsWith('MAIN'));
      expect(replies, isNotEmpty);
      view.applyEvent(
        output(102, List<String>.filled(3000, 'line\r\n').join()),
      );
      expect(view.terminal.buffer.lines.length, lessThanOrEqualTo(2000));
      expect(view.events, isEmpty);
      expect(view.lastSeq, 102);
    },
  );

  test('shared resize updates emulator without sending a resize back', () {
    final view = SessionView(
      SessionInfo.fromJson(sessionJson('t', kind: 'terminal')),
    );
    var calls = 0;
    view.terminal.onResize = (_, _, _, _) => calls++;
    view.updateInfo(
      SessionInfo.fromJson(<String, dynamic>{
        ...sessionJson('t', kind: 'terminal'),
        'cols': 120,
        'rows': 40,
      }),
    );
    expect(view.terminal.viewWidth, 120);
    expect(view.terminal.viewHeight, 40);
    expect(calls, 0);
  });

  testWidgets(
    'terminal controls send raw input and resize, disable offline and closed',
    (tester) async {
      final info = sessionJson('t', kind: 'terminal', status: 'running');
      final socket = healthyAgent(
        sessions: <Json>[info],
        capabilities: <String>['terminal'],
      );
      final c = await controllerFor(socket);
      addTearDown(c.dispose);
      await tester.pump();
      await tester.pump();
      final view = c.view(SessionInfo.fromJson(info));
      await tester.pumpWidget(
        MaterialApp(
          home: SessionScreen(controller: c, view: view),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(TerminalView), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.text('Ctrl-C'));
      await tester.pump();
      expect(socket.lastRequest('terminal_input')!['data'], '\x03');
      expect(socket.lastRequest('terminal_resize')!['cols'], greaterThan(1));
      await c.terminalInput('t', '  echo hi\r\t');
      expect(socket.lastRequest('terminal_input')!['data'], '  echo hi\r\t');
      socket.push(<String, dynamic>{'t': 'presence', 'online': false});
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Ctrl-C'))
            .onPressed,
        isNull,
      );
      expect(
        tester.widget<TerminalView>(find.byType(TerminalView)).readOnly,
        isTrue,
      );
      view.updateInfo(
        SessionInfo.fromJson(<String, dynamic>{...info, 'status': 'closed'}),
      );
      await tester.pump();
      expect(find.text('终端已结束'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'terminal IME composition, spaces and Enter reach the wire and render output',
    (tester) async {
      final info = sessionJson('ime', kind: 'terminal', status: 'running');
      final socket = healthyAgent(sessions: <Json>[info]);
      final respond = socket.onSend!;
      final received = StringBuffer();
      socket.onSend = (s, frame) {
        respond(s, frame);
        final data = frame['data'];
        if (data is Json && data['type'] == 'terminal_input') {
          received.write(data['data']);
          if (data['data'] == '\r') {
            s.msg(<String, dynamic>{
              'kind': 'event',
              'sessionId': 'ime',
              'event': <String, dynamic>{
                'kind': 'terminal_output',
                'seq': 1,
                'ts': 1,
                'data': '\x1b[32m中文命令已执行\x1b[0m\r\n',
              },
            });
          }
        }
      };
      final c = await controllerFor(socket);
      addTearDown(c.dispose);
      await tester.pump();
      await tester.pump();
      final view = c.view(SessionInfo.fromJson(info));
      await tester.pumpWidget(
        MaterialApp(
          home: SessionScreen(controller: c, view: view),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(TerminalView));
      // Let xterm finish its single/double-tap recognition window.
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(tester.testTextInput.hasAnyClients, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);

      // xterm reserves a prefix for backspace detection. Use the actual editing
      // state supplied to the IME rather than overwriting that prefix.
      String prefix() => tester.testTextInput.editingState!['text'] as String;
      void insert(String text) {
        final value = prefix() + text;
        tester.testTextInput.updateEditingValue(
          TextEditingValue(
            text: value,
            selection: TextSelection.collapsed(offset: value.length),
          ),
        );
      }

      insert('  echo ');
      await tester.pump();
      final beforeComposition = received.toString();
      final base = prefix();
      tester.testTextInput.updateEditingValue(
        TextEditingValue(
          text: '${base}zhongwen',
          selection: TextSelection.collapsed(offset: base.length + 8),
          composing: TextRange(start: base.length, end: base.length + 8),
        ),
      );
      await tester.pump();
      expect(received.toString(), beforeComposition);
      tester.testTextInput.updateEditingValue(
        TextEditingValue(
          text: '$base中文',
          selection: TextSelection.collapsed(offset: base.length + 2),
          composing: TextRange.empty,
        ),
      );
      await tester.pump();
      insert('  ');
      await tester.pump();
      // Send Enter through the platform text input client, not the toolbar or
      // controller API. This is the soft-keyboard action handled by xterm.
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(utf8.encode(received.toString()), utf8.encode('  echo 中文  \r'));
      final rendered = tester.widget<TerminalView>(find.byType(TerminalView));
      expect(rendered.terminal.buffer.getText(), startsWith('中文命令已执行'));
      expect(rendered.terminal.buffer.getText(), isNot(contains('\x1b')));

      // Physical keyboards use Flutter key events and must also deliver CR.
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(received.toString(), '  echo 中文  \r\r');
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('capable agents default to terminal and still offer Claude', (
    tester,
  ) async {
    final socket = healthyAgent(capabilities: <String>['terminal']);
    final c = await controllerFor(socket);
    addTearDown(c.dispose);
    await tester.pump();
    await tester.pump();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showNewSessionSheet(context, c),
              child: const Text('new'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('new'));
    await tester.pumpAndSettle();
    expect(find.text('要做什么'), findsNothing);
    await tester.tap(find.text('Claude'));
    await tester.pumpAndSettle();
    expect(find.text('要做什么'), findsOneWidget);
    await tester.tap(find.text('终端'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '启动'));
    await tester.pumpAndSettle();
    expect(socket.lastRequest('create_terminal')!['cwd'], r'C:\work');
    expect(socket.lastRequest('create_session'), isNull);
  });
}
