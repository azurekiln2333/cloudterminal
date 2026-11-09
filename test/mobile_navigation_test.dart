import 'dart:async';

import 'package:cloudterminal/main.dart';
import 'package:cloudterminal/screens/herdr_terminal_screen.dart';
import 'package:cloudterminal/state/app_store.dart';
import 'package:cloudterminal/state/herdr_controller.dart';
import 'package:cloudterminal/state/remote_controller.dart';
import 'package:cloudterminal/theme/app_theme.dart';
import 'package:cloudterminal/widgets/herdr_terminal_rows.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_relay.dart';

/// User-facing navigation for the phone: pairing, the Herdr entry, and the
/// tab/pane switchers.
///
/// Every case here walks a path a person actually takes ("tap this, expect to
/// see that"). Nothing asserts private fields or widget types the user cannot
/// perceive, so a refactor that keeps the behaviour keeps these tests green.
void main() {
  // -------------------------------------------------------------------------
  // Pairing: the front door must promise only what it does
  // -------------------------------------------------------------------------

  group('pairing', () {
    Future<void> pumpPair(WidgetTester tester) async {
      final store = AppStore.memory();
      await tester.pumpWidget(
        CloudTerminalApp(
          store: store,
          controller: RemoteController(
            store: store,
            connector: (_) async => FakeSocket(),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('offers pasting a link instead of an absent scanner', (
      tester,
    ) async {
      await pumpPair(tester);

      // There is no camera plugin in this app, so a control labelled "scan QR"
      // could only mislead: tapping it opened a paste field.
      expect(find.text('扫描二维码'), findsNothing);
      expect(find.text('粘贴配对链接'), findsOneWidget);

      await tester.tap(find.text('粘贴配对链接'));
      await tester.pumpAndSettle();

      expect(find.text('配对链接'), findsOneWidget);
      expect(find.text('从剪贴板粘贴'), findsOneWidget);
    });

    testWidgets('pasting the clipboard link is accepted and confirmed', (
      tester,
    ) async {
      const link =
          'cloudterminal://pair?relay=wss%3A%2F%2Frelay.example.com%2Fws'
          '&code=ABCD2345&v=1';
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async => call.method == 'Clipboard.getData'
            ? <String, dynamic>{'text': link}
            : null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      await pumpPair(tester);
      await tester.tap(find.text('粘贴配对链接'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('从剪贴板粘贴'));
      await tester.pumpAndSettle();

      // The receipt tells the user the paste was understood before they commit.
      expect(find.text('已识别 relay.example.com'), findsOneWidget);
      final connect = find.widgetWithText(FilledButton, '解析并连接');
      expect(tester.widget<FilledButton>(connect).onPressed, isNotNull);
    });
  });

  // -------------------------------------------------------------------------
  // Home: Herdr is reachable with zero PTY sessions
  // -------------------------------------------------------------------------

  group('home', () {
    testWidgets('an empty session list still walks into Herdr and back', (
      tester,
    ) async {
      final socket = _herdrHome();
      await _pumpPairedApp(tester, socket);

      // Zero PTY sessions is the case that had no Herdr path at all: the empty
      // state only mentioned creating a Claude/terminal session.
      expect(find.text('还没有会话'), findsOneWidget);
      final entry = find.text('打开 Herdr（1 个工作区）');
      expect(entry, findsOneWidget);

      await tester.tap(entry);
      await tester.pumpAndSettle();

      expect(find.text('Herdr 工作区'), findsOneWidget);
      expect(find.text('cloudterminal'), findsOneWidget);

      // The page is a pushed route, so it must expose a real way back. It used
      // to show the root drawer button instead, leaving no visible exit.
      expect(find.byType(BackButton), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('还没有会话'), findsOneWidget);
    });

    testWidgets('the app bar opens Herdr directly', (tester) async {
      await _pumpPairedApp(tester, _herdrHome());

      await tester.tap(find.byTooltip('Herdr 工作区'));
      await tester.pumpAndSettle();

      expect(find.text('Herdr 工作区'), findsOneWidget);
      expect(find.text('cloudterminal'), findsOneWidget);
    });

    testWidgets('a drawer workspace opens that workspace, not just the PC', (
      tester,
    ) async {
      final socket = _herdrHome();
      await _pumpPairedApp(tester, socket);

      await tester.tap(find.byTooltip('工作空间'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, 'cloudterminal'));
      await tester.pumpAndSettle();

      // Tapping landed on the workspace the user pointed at: expanded, with its
      // panes listed. Previously it only sent `workspace_focus` and closed the
      // drawer onto an unchanged session list, which read as a dead tap.
      expect(find.text('Herdr 工作区'), findsOneWidget);
      expect(find.text('面板'), findsOneWidget);
      // The desktop follows too, so the two screens never disagree.
      expect(
        socket.requests
            .where((r) => r['type'] == 'herdr_act')
            .map((r) => r['action']['kind']),
        contains('workspace_focus'),
      );
    });

    testWidgets('the workspace menu offers the terminal, not just PC focus', (
      tester,
    ) async {
      await _pumpPairedApp(tester, _herdrHome());

      await tester.tap(find.byTooltip('Herdr 工作区'));
      await tester.pumpAndSettle();
      // Expand so the focused pane is known to the menu.
      await tester.tap(find.text('cloudterminal'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('工作区操作'));
      await tester.pumpAndSettle();

      expect(find.text('打开终端'), findsOneWidget);
      expect(find.text('在电脑上切换'), findsOneWidget);
    });

    testWidgets('a pane opens a real terminal, with no PTY session created', (
      tester,
    ) async {
      final socket = _herdrHome();
      await _pumpPairedApp(tester, socket);

      // Zero PTY sessions → the Herdr entry → the workspace → one pane.
      await tester.tap(find.text('打开 Herdr（1 个工作区）'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('cloudterminal'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('pi · main'));
      await tester.pumpAndSettle();

      // The pane terminal is a screen of its own, independent of any session.
      expect(find.byType(HerdrTerminalScreen), findsOneWidget);
      // Its own tab/pane rows are present, so switching works without leaving.
      expect(find.text('scratch'), findsOneWidget);
      // The phone subscribed to the pane it opened …
      expect(
        socket.requests
            .where((r) => r['type'] == 'herdr_watch')
            .map((r) => r['paneId']),
        contains('wJ:p1'),
      );
      // … and pushed screen content arrived for it.
      expect(
        socket.requests.any((r) => r['type'] == 'create_terminal'),
        isFalse,
        reason: 'a Herdr pane must never spawn a PTY session',
      );
    });
  });

  // -------------------------------------------------------------------------
  // Terminal rows: a tab tap has to change what the phone watches
  // -------------------------------------------------------------------------

  group('herdr rows', () {
    testWidgets('tapping a tab switches the pane the phone watches', (
      tester,
    ) async {
      final harness = await _pumpRows(tester);

      // Tab 1 owns wJ:p1; tab 2 owns wJ:p4.
      expect(find.text('pi · main'), findsOneWidget);
      expect(find.text('shell · scratch'), findsNothing);

      await tester.tap(find.text('scratch'));
      await tester.pumpAndSettle();

      // The rows now describe tab 2 …
      expect(find.text('shell · scratch'), findsOneWidget);
      // … and the stream followed, instead of leaving the terminal on the tab
      // the user just left.
      expect(
        harness.socket.requests
            .where((r) => r['type'] == 'herdr_watch')
            .map((r) => r['paneId'])
            .toList(),
        contains('wJ:p4'),
      );
    });

    testWidgets('a failed switch is explained and can be dismissed', (
      tester,
    ) async {
      final harness = await _pumpRows(tester, actError: true);

      await tester.tap(find.text('shell · other'));
      await tester.pumpAndSettle();

      // The reason is readable text, not a one-line clipped bar.
      expect(find.text('pane not found'), findsOneWidget);

      await tester.tap(find.byTooltip('关闭提示'));
      await tester.pump();
      expect(find.text('pane not found'), findsNothing);
      expect(harness.herdr.error, isNotNull);
    });
  });
}

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

class _RowsHarness {
  _RowsHarness(this.socket, this.herdr);
  final FakeSocket socket;
  final HerdrController herdr;
}

/// A paired app whose agent reports Herdr with one workspace and no sessions.
FakeSocket _herdrHome() {
  final socket = healthyAgent(
    sessions: const <Map<String, dynamic>>[],
    capabilities: const <String>['terminal', 'herdr'],
  );
  _scriptHerdr(socket, keepPrevious: true);
  return socket;
}

Future<void> _pumpPairedApp(WidgetTester tester, FakeSocket socket) async {
  final store = AppStore.memory();
  await store.setPairing(
    const Pairing(
      relayUrl: 'wss://r/ws',
      agentId: 'a_x',
      secret: 's',
      name: 'DESKTOP',
    ),
  );
  final controller = RemoteController(
    store: store,
    connector: (_) async => socket,
  );
  // `CloudTerminalApp` owns the controller and disposes it with the widget, so
  // disposing it here as well would throw.
  await tester.pumpWidget(
    CloudTerminalApp(store: store, controller: controller),
  );
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

/// Pumps the Herdr switcher rows on their own, so the case is about the rows and
/// not about whichever screen currently hosts them.
Future<_RowsHarness> _pumpRows(
  WidgetTester tester, {
  bool actError = false,
}) async {
  final store = AppStore.memory();
  await store.setPairing(
    const Pairing(relayUrl: 'wss://r/ws', agentId: 'a_x', secret: 's'),
  );
  final socket = healthyAgent(
    sessions: const <Map<String, dynamic>>[],
    capabilities: const <String>['terminal', 'herdr'],
  );
  _scriptHerdr(socket, keepPrevious: true, actError: actError);
  final remote = RemoteController(store: store, connector: (_) async => socket);
  final herdr = HerdrController(remote);
  addTearDown(() {
    herdr.dispose();
    remote.dispose();
  });
  remote.connect();
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(AppTheme.seeds.first.color),
      // Wrapped the way the hosting terminal screen wraps it: the rows read the
      // controller, they do not listen to it.
      home: Scaffold(
        body: ListenableBuilder(
          listenable: herdr,
          builder: (context, _) => HerdrTerminalRows(herdr: herdr),
        ),
      ),
    ),
  );
  // The capability probe, the workspace listing and the tab/pane load are four
  // sequential round trips; settle them all before asserting.
  await tester.pumpAndSettle();
  return _RowsHarness(socket, herdr);
}

// ---------------------------------------------------------------------------
// Scripted desktop agent
// ---------------------------------------------------------------------------

Map<String, dynamic> _workspace() => <String, dynamic>{
  'workspaceId': 'wJ',
  'label': 'cloudterminal',
  'number': 13,
  'focused': true,
  'agentStatus': 'working',
  'paneCount': 2,
  'tabCount': 2,
  'activeTabId': 'wJ:t1',
};

Map<String, dynamic> _tab(String id, String label, int number, bool focused) =>
    <String, dynamic>{
      'tabId': id,
      'workspaceId': 'wJ',
      'label': label,
      'number': number,
      'focused': focused,
      'agentStatus': 'idle',
      'paneCount': 1,
    };

Map<String, dynamic> _pane(
  String id,
  String tabId,
  String title, {
  bool focused = false,
}) => <String, dynamic>{
  'paneId': id,
  'workspaceId': 'wJ',
  'tabId': tabId,
  'cwd': r'D:\work',
  'focused': focused,
  'terminalTitle': title,
  'agent': 'pi',
  'agentStatus': 'idle',
};

/// Answers the Herdr request/reply loop the way the real agent does.
///
/// [keepPrevious] preserves the base agent's hello/info/list_sessions replies so
/// the app reaches `online` and then layers only the `herdr_*` traffic.
void _scriptHerdr(
  FakeSocket socket, {
  bool keepPrevious = false,
  bool actError = false,
}) {
  // The desktop's focus is the truth the rows follow, so the script keeps it
  // instead of faking a static answer.
  var focusedTabId = 'wJ:t1';
  var focusedPaneId = 'wJ:p1';
  final previous = socket.onSend;

  List<Map<String, dynamic>> panes() => <Map<String, dynamic>>[
    _pane('wJ:p1', 'wJ:t1', 'pi · main', focused: focusedPaneId == 'wJ:p1'),
    _pane('wJ:p2', 'wJ:t1', 'shell · other', focused: focusedPaneId == 'wJ:p2'),
    _pane('wJ:p4', 'wJ:t2', 'shell · scratch', focused: focusedPaneId == 'wJ:p4'),
  ];

  socket.onSend = (s, frame) {
    final data = frame['data'];
    if (keepPrevious &&
        (data is! Map<String, dynamic> ||
            !(data['type'] as String? ?? '').startsWith('herdr_'))) {
      previous?.call(s, frame);
      return;
    }
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
    final map = data as Map<String, dynamic>;
    final id = map['id'];
    scheduleMicrotask(() {
      switch (map['type']) {
        case 'info':
          s.msg(<String, dynamic>{
            'kind': 'info',
            'id': id,
            'host': 'DESKTOP',
            'platform': 'win32',
            'defaultCwd': r'D:\work',
            'roots': <String>[r'D:\work'],
            'allowBypass': false,
            'capabilities': <String>['terminal', 'herdr'],
          });
        case 'list_sessions':
          s.msg(<String, dynamic>{
            'kind': 'sessions',
            'id': id,
            'sessions': <dynamic>[],
          });
        case 'herdr_info':
          s.msg(<String, dynamic>{
            'kind': 'herdr_info',
            'id': id,
            'availability': <String, dynamic>{
              'available': true,
              'installed': true,
              'serverRunning': true,
              'canControl': true,
              'version': '0.9.3',
              'protocol': 22,
            },
          });
        case 'herdr_workspaces':
          s.msg(<String, dynamic>{
            'kind': 'herdr_workspaces',
            'id': id,
            'workspaces': <Map<String, dynamic>>[_workspace()],
          });
        case 'herdr_agents':
          s.msg(<String, dynamic>{
            'kind': 'herdr_agents',
            'id': id,
            'agents': <dynamic>[],
          });
        case 'herdr_tabs':
          s.msg(<String, dynamic>{
            'kind': 'herdr_tabs',
            'id': id,
            'workspaceId': map['workspaceId'],
            'tabs': <Map<String, dynamic>>[
              _tab('wJ:t1', 'main', 1, focusedTabId == 'wJ:t1'),
              _tab('wJ:t2', 'scratch', 2, focusedTabId == 'wJ:t2'),
            ],
          });
        case 'herdr_panes':
          s.msg(<String, dynamic>{
            'kind': 'herdr_panes',
            'id': id,
            'workspaceId': map['workspaceId'],
            'panes': panes(),
          });
        case 'herdr_watch':
          // The agent answers a subscription with the pane's rendered screen. A
          // real push, so the pane terminal has content to show.
          final watched = map['paneId'];
          if (watched is String) {
            s.msg(<String, dynamic>{
              'kind': 'herdr_pane_output',
              'paneId': watched,
              'revision': 1,
              'format': 'ansi',
              'reset': true,
              'prefix': 0,
              'chunk': 'live pane output\r\n',
            });
          }
          s.msg(<String, dynamic>{'kind': 'ack', 'id': id});
        case 'herdr_act':
          if (actError) {
            s.msg(<String, dynamic>{
              'kind': 'error',
              'id': id,
              'message': 'herdr_failed:pane_focus:pane not found',
            });
            return;
          }
          final action = map['action'];
          if (action is Map<String, dynamic>) {
            if (action['kind'] == 'tab_focus') {
              focusedTabId = action['tabId'] as String;
              focusedPaneId = focusedTabId == 'wJ:t2' ? 'wJ:p4' : 'wJ:p1';
            } else if (action['kind'] == 'pane_focus') {
              focusedPaneId = action['paneId'] as String;
            }
          }
          s.msg(<String, dynamic>{
            'kind': 'herdr_result',
            'id': id,
            'action': 'ok',
            'summary': '已执行',
          });
        default:
          s.msg(<String, dynamic>{'kind': 'ack', 'id': id});
      }
    });
  };
}
