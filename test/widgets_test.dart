
import 'package:cloudterminal/main.dart';
import 'package:cloudterminal/screens/session_screen.dart';
import 'package:cloudterminal/state/app_store.dart';
import 'package:cloudterminal/state/remote_controller.dart';
import 'package:cloudterminal/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_relay.dart';

Map<String, dynamic> ev(int seq, String kind, [Map<String, dynamic> extra = const <String, dynamic>{}]) =>
    <String, dynamic>{'kind': kind, 'seq': seq, 'ts': seq, ...extra};

void main() {
  testWidgets('shows the pair screen when not paired', (tester) async {
    final store = AppStore.memory();
    await tester.pumpWidget(CloudTerminalApp(
      store: store,
      controller: RemoteController(store: store, connector: (_) async => FakeSocket()),
    ));
    await tester.pumpAndSettle();

    expect(find.text('连接你的电脑'), findsOneWidget);
    final connect = find.widgetWithText(FilledButton, '连接');
    expect(tester.widget<FilledButton>(connect).onPressed, isNull);

    await tester.enterText(find.byType(TextField).at(0), 'relay.example.com');
    await tester.enterText(find.byType(TextField).at(1), 'abcd2345');
    await tester.pump();
    // Formatter upper-cases and inserts the dash.
    expect(find.text('ABCD-2345'), findsOneWidget);
    expect(tester.widget<FilledButton>(connect).onPressed, isNotNull);

    await tester.tap(find.text('手动填写'));
    await tester.pumpAndSettle();
    expect(find.text('设备 ID'), findsOneWidget);
  });

  testWidgets('home lists sessions from the agent', (tester) async {
    final store = AppStore.memory();
    await store.setPairing(const Pairing(relayUrl: 'wss://r/ws', agentId: 'a_x', secret: 's'));
    final socket = healthyAgent(sessions: <Map<String, dynamic>>[
      sessionJson('s1', title: '重构登录模块', status: 'running'),
      sessionJson('s2', title: '修复构建', status: 'waiting', pending: 2),
    ]);
    await tester.pumpWidget(CloudTerminalApp(
      store: store,
      controller: RemoteController(store: store, connector: (_) async => socket),
    ));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('DESKTOP'), findsOneWidget);
    expect(find.text('已连接'), findsOneWidget);
    expect(find.text('重构登录模块'), findsOneWidget);
    expect(find.text('2 个请求待授权'), findsOneWidget);
    // The session waiting for approval is listed first.
    final waitingY = tester.getTopLeft(find.text('修复构建')).dy;
    final runningY = tester.getTopLeft(find.text('重构登录模块')).dy;
    expect(waitingY, lessThan(runningY));
  });

  group('session screen', () {
    late FakeSocket socket;
    late RemoteController controller;

    Future<void> open(WidgetTester tester, List<Map<String, dynamic>> backlog, {String status = 'waiting'}) async {
      final store = AppStore.memory();
      await store.setPairing(const Pairing(relayUrl: 'wss://r/ws', agentId: 'a_x', secret: 's'));
      socket = healthyAgent(
        sessions: <Map<String, dynamic>>[sessionJson('s1', status: status, pending: 1)],
        backlog: <String, List<Map<String, dynamic>>>{'s1': backlog},
      );
      controller = RemoteController(store: store, connector: (_) async => socket)..connect();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      final view = controller.view(controller.session('s1')!);
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(AppTheme.seeds.first.color),
        home: SessionScreen(controller: controller, view: view),
      ));
      await tester.pump();
      await tester.pump();
    }

    tearDown(() => controller.dispose());

    testWidgets('renders the transcript and answers a permission request', (tester) async {
      await open(tester, <Map<String, dynamic>>[
        ev(1, 'user', <String, dynamic>{'text': '跑一下测试'}),
        ev(2, 'assistant', <String, dynamic>{'text': '好的，我来运行测试。'}),
        ev(3, 'tool_use', <String, dynamic>{
          'toolUseId': 't1',
          'name': 'Bash',
          'summary': 'npm test',
          'input': <String, dynamic>{'command': 'npm test'},
        }),
        ev(4, 'permission_request', <String, dynamic>{
          'requestId': 'p1',
          'toolName': 'Bash',
          'title': 'Claude 想要运行 npm test',
          'input': <String, dynamic>{'command': 'npm test'},
          'canAlwaysAllow': true,
        }),
      ]);

      expect(find.text('跑一下测试'), findsOneWidget);
      expect(find.text('好的，我来运行测试。'), findsOneWidget);
      expect(find.text('Claude 想要运行 npm test'), findsOneWidget);
      expect(find.text('始终允许'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, '允许'));
      await tester.pump();
      final req = socket.lastRequest('permission')!;
      expect(req['requestId'], 'p1');
      expect(req['decision'], 'allow');

      // Resolution arrives: card goes away, transcript shows the decision.
      socket.msg(<String, dynamic>{
        'kind': 'event',
        'sessionId': 's1',
        'event': ev(5, 'permission_resolved', <String, dynamic>{'requestId': 'p1', 'decision': 'allow'}),
      });
      await tester.pump();
      await tester.pump();
      expect(find.text('始终允许'), findsNothing);
      expect(find.textContaining('已允许'), findsOneWidget);
    });

    testWidgets('answers AskUserQuestion with the chosen option', (tester) async {
      await open(tester, <Map<String, dynamic>>[
        ev(1, 'permission_request', <String, dynamic>{
          'requestId': 'q1',
          'toolName': 'AskUserQuestion',
          'title': 'Claude 有问题想问你',
          'input': null,
          'canAlwaysAllow': false,
          'questions': <dynamic>[
            <String, dynamic>{
              'question': '用哪个数据库？',
              'header': '数据库',
              'options': <dynamic>[
                <String, dynamic>{'label': 'PostgreSQL', 'description': '关系型'},
                <String, dynamic>{'label': 'SQLite', 'description': '嵌入式'},
              ],
            },
          ],
        }),
      ]);

      final submit = find.widgetWithText(FilledButton, '提交回答');
      expect(tester.widget<FilledButton>(submit).onPressed, isNull);
      await tester.tap(find.text('SQLite'));
      await tester.pump();
      expect(tester.widget<FilledButton>(submit).onPressed, isNotNull);
      await tester.tap(submit);
      await tester.pump();

      final req = socket.lastRequest('permission')!;
      expect(req['decision'], 'allow');
      expect(req['answers'], <String, String>{'用哪个数据库？': 'SQLite'});
    });

    testWidgets('sends messages and shows streamed text', (tester) async {
      await open(tester, <Map<String, dynamic>>[ev(1, 'user', <String, dynamic>{'text': 'hi'})], status: 'running');

      socket.msg(<String, dynamic>{'kind': 'delta', 'sessionId': 's1', 'text': '正在分析代码'});
      await tester.pump();
      expect(find.text('正在分析代码'), findsOneWidget);
      expect(find.byTooltip('停止'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '顺便更新 README');
      await tester.pump();
      await tester.tap(find.byTooltip('发送'));
      await tester.pump();
      await tester.pump();
      expect(socket.lastRequest('send'), containsPair('text', '顺便更新 README'));

      await tester.tap(find.byTooltip('停止'));
      await tester.pump();
      expect(socket.lastRequest('interrupt'), isNotNull);
    });
  });
}
