import 'package:cloudterminal/main.dart';
import 'package:cloudterminal/models/protocol.dart';
import 'package:cloudterminal/screens/codex_screen.dart';
import 'package:cloudterminal/state/app_store.dart';
import 'package:cloudterminal/state/codex_catalog.dart';
import 'package:cloudterminal/state/codex_thread_view.dart';
import 'package:cloudterminal/state/remote_controller.dart';
import 'package:cloudterminal/theme/app_theme.dart';
import 'package:cloudterminal/widgets/terminal_pane.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/codex_fixture.dart';

Future<(RemoteController, AppStore)> connect(CodexFixture fixture) async {
  final store = AppStore.memory();
  await store.setPairing(
    const Pairing(
      relayUrl: 'wss://fixture/ws',
      agentId: 'fixture',
      secret: 'fixture',
    ),
  );
  final controller = RemoteController(
    store: store,
    connector: (_) async => fixture.socket,
  )..connect();
  for (var i = 0; i < 20 && controller.agent == null; i++) {
    await Future<void>.delayed(Duration.zero);
  }
  return (controller, store);
}

Future<void> flush() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test('catalog pages deduplicate and preserve project filters', () async {
    final fixture = CodexFixture();
    final (controller, _) = await connect(fixture);
    addTearDown(controller.dispose);
    final catalog = CodexCatalog(controller);
    addTearDown(catalog.dispose);
    await flush();
    expect(catalog.projects.map((p) => p.id), <String>['project-1']);
    await catalog.loadProjects();
    expect(catalog.projects.map((p) => p.id), <String>[
      'project-1',
      'project-2',
    ]);
    await catalog.loadThreads('project-1');
    await catalog.loadThreads('project-1');
    expect(catalog.threads('project-1').items.length, 2);
    expect(
      fixture.socket.lastRequest('codex_threads'),
      containsPair('projectId', 'project-1'),
    );
    expect(
      fixture.socket.lastRequest('codex_threads'),
      containsPair('cursor', 'threads-2'),
    );
    final count = fixture.socket.requests.length;
    await catalog.loadThreads('project-1');
    expect(fixture.socket.requests.length, count);
  });

  test(
    'transcript pages prepend earlier turns, notices refresh and errors disable control',
    () async {
      final fixture = CodexFixture(canControl: true, canInput: true);
      final (controller, _) = await connect(fixture);
      addTearDown(controller.dispose);
      final view = CodexThreadView(
        controller,
        CodexThread.fromJson(fixture.thread()),
      );
      addTearDown(view.dispose);
      await flush();
      expect(view.canSend, isTrue);
      await view.load();
      expect(view.turns.map((t) => t.id), <String>['turn-1', 'turn-2']);
      expect(view.nextCursor, isNull);
      fixture.canInput = false;
      fixture.socket.msg(<String, dynamic>{
        'kind': 'codex_changed',
        'threadId': 'thread-1',
      });
      await flush();
      expect(view.canSend, isFalse);
      expect(view.turns.length, 2);
      fixture.readError = '代理不可用';
      await view.load(refresh: true);
      expect(view.error, '代理不可用');
      expect(view.canControl, isFalse);
      expect(view.turns.length, 2);
      fixture.readError = null;
      await view.load(refresh: true);
      expect(view.error, isNull);
    },
  );

  test('unavailable daemon makes no catalog or transcript requests', () async {
    final fixture = CodexFixture(available: false);
    final (controller, _) = await connect(fixture);
    addTearDown(controller.dispose);
    final catalog = CodexCatalog(controller);
    final view = CodexThreadView(
      controller,
      CodexThread.fromJson(fixture.thread()),
    );
    addTearDown(catalog.dispose);
    addTearDown(view.dispose);
    await catalog.loadProjects();
    await view.load();
    expect(
      fixture.socket.requests.where(
        (r) => (r['type'] as String).startsWith('codex_'),
      ),
      isEmpty,
    );
  });

  testWidgets(
    'phone drawer opens real project history and paginates transcript',
    (tester) async {
      tester.view.physicalSize = const Size(430, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = CodexFixture();
      final store = AppStore.memory();
      await store.setPairing(
        const Pairing(
          relayUrl: 'wss://fixture/ws',
          agentId: 'fixture',
          secret: 'fixture',
        ),
      );
      await tester.pumpWidget(
        CloudTerminalApp(
          store: store,
          controller: RemoteController(
            store: store,
            connector: (_) async => fixture.socket,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(NavigationDrawer), findsNothing);
      await tester.tap(find.byTooltip('工作空间'));
      await tester.pumpAndSettle();
      expect(find.byType(NavigationDrawer), findsOneWidget);
      expect(find.text('终端'), findsOneWidget);
      await tester.tap(find.text('项目一'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('修复桌面任务'));
      await tester.pumpAndSettle();
      expect(find.byType(CodexScreen), findsOneWidget);
      expect(find.text('最近的回答'), findsOneWidget);
      expect(find.textContaining('只读历史'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.text('加载更早记录'));
      await tester.pumpAndSettle();
      expect(find.text('更早的回答'), findsOneWidget);
      expect(
        fixture.socket.lastRequest('codex_read'),
        containsPair('cursor', 'earlier-turns'),
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'wide sidebar stays visible across Codex and managed terminal navigation',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = CodexFixture();
      final store = AppStore.memory();
      await store.setPairing(
        const Pairing(
          relayUrl: 'wss://fixture/ws',
          agentId: 'fixture',
          secret: 'fixture',
        ),
      );
      await tester.pumpWidget(
        CloudTerminalApp(
          store: store,
          controller: RemoteController(
            store: store,
            connector: (_) async => fixture.socket,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(NavigationDrawer), findsOneWidget);
      expect(find.byTooltip('工作空间'), findsNothing);
      await tester.tap(find.text('项目一'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('修复桌面任务'));
      await tester.pumpAndSettle();
      expect(find.byType(CodexScreen), findsOneWidget);
      expect(find.byType(NavigationDrawer), findsOneWidget);
      await tester.tap(find.text('本机终端').first);
      await tester.pumpAndSettle();
      expect(find.byType(TerminalPane), findsOneWidget);
      expect(find.byType(NavigationDrawer), findsOneWidget);
      await tester.tap(find.text('终端'));
      await tester.pumpAndSettle();
      expect(find.text('新建会话'), findsOneWidget);
      expect(fixture.socket.lastRequest('codex_send'), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  Future<RemoteController> openThread(
    WidgetTester tester,
    CodexFixture fixture,
  ) async {
    final store = AppStore.memory();
    await store.setPairing(
      const Pairing(
        relayUrl: 'wss://fixture/ws',
        agentId: 'fixture',
        secret: 'fixture',
      ),
    );
    final controller = RemoteController(
      store: store,
      connector: (_) async => fixture.socket,
    )..connect();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(AppTheme.seeds.first.color),
        home: CodexScreen(
          controller: controller,
          thread: CodexThread.fromJson(fixture.thread()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    addTearDown(controller.dispose);
    return controller;
  }

  testWidgets(
    'restores history, sends and steers only when direct input is accepted',
    (tester) async {
      final fixture = CodexFixture(canControl: true, canResume: true);
      await openThread(tester, fixture);
      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.text('恢复会话'));
      await tester.pumpAndSettle();
      expect(
        fixture.socket.lastRequest('codex_resume'),
        containsPair('threadId', 'thread-1'),
      );
      await tester.enterText(find.byType(TextField), '继续测试任务');
      await tester.pump();
      await tester.tap(find.byTooltip('发送给 Codex'));
      await tester.pumpAndSettle();
      expect(
        fixture.socket.lastRequest('codex_send'),
        containsPair('text', '继续测试任务'),
      );
      expect(
        fixture.socket.lastRequest('codex_send')!.containsKey('turnId'),
        isFalse,
      );
      await tester.enterText(find.byType(TextField), '补充说明');
      await tester.pump();
      await tester.tap(find.byTooltip('发送给 Codex'));
      await tester.pumpAndSettle();
      expect(
        fixture.socket.lastRequest('codex_send'),
        containsPair('turnId', 'running-turn'),
      );
      await tester.tap(find.byTooltip('停止 Codex'));
      await tester.pumpAndSettle();
      expect(
        fixture.socket.lastRequest('codex_interrupt'),
        containsPair('turnId', 'running-turn'),
      );
      fixture.socket.push(<String, dynamic>{'t': 'presence', 'online': false});
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      expect(find.textContaining('电脑离线'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('pending command and user-input approvals remain actionable', (
    tester,
  ) async {
    final fixture = CodexFixture(canControl: true, canInput: true);
    fixture.pending = <Map<String, dynamic>>[
      <String, dynamic>{
        'requestId': 'approval-1',
        'kind': 'command',
        'title': '运行测试命令',
        'canAccept': true,
      },
    ];
    await openThread(tester, fixture);
    await tester.tap(find.widgetWithText(FilledButton, '允许'));
    await tester.pumpAndSettle();
    expect(
      fixture.socket.lastRequest('codex_respond'),
      containsPair('decision', 'accept'),
    );
    fixture.pending = <Map<String, dynamic>>[
      <String, dynamic>{
        'requestId': 'question-1',
        'kind': 'userInput',
        'title': '请选择测试环境',
        'canAccept': true,
        'questions': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'env',
            'question': '在哪运行？',
            'options': <Map<String, dynamic>>[
              <String, dynamic>{'label': '本地'},
              <String, dynamic>{'label': '隔离环境'},
            ],
          },
        ],
      },
    ];
    fixture.socket.msg(<String, dynamic>{
      'kind': 'codex_pending',
      'threadId': 'thread-1',
    });
    await tester.pumpAndSettle();
    final submit = find.widgetWithText(FilledButton, '提交回答');
    expect(tester.widget<FilledButton>(submit).onPressed, isNull);
    await tester.tap(find.text('隔离环境'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(submit);
    await tester.tap(submit);
    await tester.pumpAndSettle();
    expect(
      fixture.socket.lastRequest('codex_respond')!['answers'],
      <String, List<String>>{
        'env': <String>['隔离环境'],
      },
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('unavailable desktop displays reason without invented history', (
    tester,
  ) async {
    final fixture = CodexFixture(available: false);
    await openThread(tester, fixture);
    expect(find.text('请先启动 Codex Desktop'), findsOneWidget);
    expect(find.text('最近的回答'), findsNothing);
    expect(find.byType(TextField), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
