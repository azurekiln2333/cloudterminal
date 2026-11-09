// Phone acceptance: end-to-end user journeys through the real Herdr terminal.
//
// This file is deliberately *not* a unit suite. The per-mechanism tests live in
// `test/herdr_direct_input_test.dart` (an ordered queue, a pane-epoch guard, a
// clipboard race, …); what is checked here is the thing a person holding the
// phone would notice:
//
//   * a desktop-width line is fully readable after the phone reflows it,
//   * Chinese text wraps without a broken glyph and without losing the tail,
//   * opening the soft keyboard does not cost the user rows of their screen,
//   * tapping the terminal types into the pane, in the bytes a PC would send,
//   * switching panes sends each keystroke to the pane it was typed in,
//   * a dropped link is recoverable and never replays the input it swallowed.
//
// Every assertion is made against what the user can see (the emulator's grid) or
// against the bytes the app put on the wire — never against a private helper,
// and never by re-deriving the production result in the test.

import 'dart:async';

import 'package:cloudterminal/models/herdr.dart';
import 'package:cloudterminal/net/relay_socket.dart';
import 'package:cloudterminal/screens/herdr_terminal_screen.dart';
import 'package:cloudterminal/state/app_store.dart';
import 'package:cloudterminal/state/herdr_controller.dart';
import 'package:cloudterminal/state/remote_controller.dart';
import 'package:cloudterminal/theme/app_theme.dart';
import 'package:cloudterminal/widgets/herdr_terminal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

import 'support/fake_relay.dart';

// ---------------------------------------------------------------------------
// A desktop pane, as the agent reports it
// ---------------------------------------------------------------------------

Map<String, dynamic> _availability() => <String, dynamic>{
  'available': true,
  'installed': true,
  'serverRunning': true,
  'canControl': true,
  'version': '0.9.3',
  'protocol': 22,
  'socket': r'D:\AppData\Roaming\herdr\herdr.sock',
};

Map<String, dynamic> _workspace() => <String, dynamic>{
  'workspaceId': 'wJ',
  'label': 'cloudterminal',
  'number': 13,
  'focused': true,
  'agentStatus': 'idle',
  'paneCount': 2,
  'tabCount': 1,
  'activeTabId': 'wJ:t1',
};

Map<String, dynamic> _tab() => <String, dynamic>{
  'tabId': 'wJ:t1',
  'workspaceId': 'wJ',
  'label': 'main',
  'number': 1,
  'focused': true,
  'agentStatus': 'idle',
  'paneCount': 2,
};

Map<String, dynamic> _pane(String paneId, {String? name, bool focused = false}) =>
    <String, dynamic>{
      'paneId': paneId,
      'workspaceId': 'wJ',
      'tabId': 'wJ:t1',
      'cwd': r'D:\MyNewProjects\cloudterminal',
      'focused': focused,
      'terminalTitle': 'π - cloudterminal',
      'name': ?name,
    };

/// An agent that answers the calls these journeys make.
///
/// `sendError` makes every write fail, which is how the "you are typing into a
/// pane that is gone" path is reached from the UI.
FakeSocket _agentSocket({
  String outputText = '',
  String? sendError,
  int sendDelayMs = 0,
  List<Map<String, dynamic>>? panes,
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
    void reply(void Function() body) {
      if (sendDelayMs > 0) {
        Future<void>.delayed(Duration(milliseconds: sendDelayMs), body);
      } else {
        scheduleMicrotask(body);
      }
    }

    if (data['type'] == 'herdr_send_text') {
      reply(() {
        if (sendError != null) {
          s.msg(<String, dynamic>{'kind': 'error', 'id': id, 'message': sendError});
        } else {
          s.msg(<String, dynamic>{'kind': 'herdr_result', 'id': id});
        }
      });
      return;
    }
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
            'capabilities': <String>['terminal', 'herdr'],
            'herdr': _availability(),
          });
        case 'list_sessions':
          s.msg(<String, dynamic>{'kind': 'sessions', 'id': id, 'sessions': <dynamic>[]});
        case 'herdr_info':
          s.msg(<String, dynamic>{
            'kind': 'herdr_info',
            'id': id,
            'availability': _availability(),
          });
        case 'herdr_workspaces':
          s.msg(<String, dynamic>{
            'kind': 'herdr_workspaces',
            'id': id,
            'workspaces': <Map<String, dynamic>>[_workspace()],
          });
        case 'herdr_agents':
          s.msg(<String, dynamic>{'kind': 'herdr_agents', 'id': id, 'agents': <dynamic>[]});
        case 'herdr_tabs':
          s.msg(<String, dynamic>{
            'kind': 'herdr_tabs',
            'id': id,
            'workspaceId': data['workspaceId'],
            'tabs': <Map<String, dynamic>>[_tab()],
          });
        case 'herdr_panes':
          s.msg(<String, dynamic>{
            'kind': 'herdr_panes',
            'id': id,
            'workspaceId': data['workspaceId'],
            'panes':
                panes ??
                <Map<String, dynamic>>[
                  _pane('wJ:p2', name: 'shell', focused: true),
                  _pane('wJ:p3', name: 'pi'),
                ],
          });
        case 'herdr_watch':
          s.msg(<String, dynamic>{
            'kind': 'herdr_watch_result',
            'id': id,
            'paneId': data['paneId'],
          });
        case 'herdr_read':
          s.msg(<String, dynamic>{
            'kind': 'herdr_output',
            'id': id,
            'paneId': data['paneId'],
            'source': data['source'],
            'text': outputText,
          });
        default:
          s.msg(<String, dynamic>{'kind': 'ack', 'id': id});
      }
    });
  };
  return socket;
}

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

/// A controller over [sockets], one per connection attempt.
///
/// More than one socket is what makes "the link dropped and came back" a real
/// journey: the second attempt is a different object, exactly as a fresh TLS
/// connection would be.
Future<RemoteController> _controllerFor(List<FakeSocket> sockets) async {
  final store = AppStore.memory();
  await store.setPairing(
    const Pairing(relayUrl: 'wss://r/ws', agentId: 'a', secret: 's'),
  );
  final pending = List<FakeSocket>.of(sockets);
  return RemoteController(
    store: store,
    connector: (_) async {
      if (pending.isEmpty) {
        // Park the retry loop instead of failing: an unexpected extra attempt
        // must not turn into a connection error the test misreads.
        return Completer<RelaySocket>().future;
      }
      return pending.removeAt(0);
    },
  )..connect();
}

class _Phone {
  _Phone(this.sockets, this.remote, this.herdr);

  final List<FakeSocket> sockets;
  final RemoteController remote;
  final HerdrController herdr;

  /// The link that is currently up.
  ///
  /// A recovery journey has more than one socket; the first stays in [sockets]
  /// (its traffic is the evidence of what the dead link received) but is no
  /// longer the one the app talks on.
  FakeSocket get socket =>
      sockets.firstWhere((s) => !s.closed, orElse: () => sockets.last);

  bool _disposed = false;

  /// Every write that reached the *current* link, in order.
  List<({String paneId, String text})> get writes => <({String paneId, String text})>[
    for (final r in socket.requests)
      if (r['type'] == 'herdr_send_text')
        (paneId: r['paneId'] as String, text: r['text'] as String),
  ];

  /// What was typed into [paneId], concatenated — the byte stream the PC saw.
  String typedInto(String paneId) => writes
      .where((w) => w.paneId == paneId)
      .map((w) => w.text)
      .join();

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    herdr.dispose();
    remote.dispose();
  }
}

Future<_Phone> _phone(
  WidgetTester tester, {
  List<FakeSocket>? sockets,
  String paneId = 'wJ:p2',
  bool asScreen = false,
  bool typing = true,
}) async {
  final list = sockets ?? <FakeSocket>[_agentSocket()];
  final remote = await _controllerFor(list);
  await tester.pump();
  final herdr = HerdrController(remote);
  final phone = _Phone(list, remote, herdr);
  addTearDown(phone.dispose);
  if (asScreen) {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(AppTheme.seeds.first.color),
        home: HerdrTerminalScreen(
          controller: remote,
          herdr: herdr,
          paneId: paneId,
        ),
      ),
    );
  } else {
    // Mounted directly so a pane switch is a rebuild, not a navigation: this is
    // the shape the workspace screen uses.
    if (typing) herdr.watchPane(paneId, explicit: true);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(AppTheme.seeds.first.color),
        home: Scaffold(
          body: HerdrTerminal(
            controller: remote,
            herdr: herdr,
            paneId: paneId,
            enabled: typing,
          ),
        ),
      ),
    );
  }
  await tester.pumpAndSettle();
  return phone;
}

/// Pushes a desktop screen into the pane the way the agent does.
Future<void> _screen(
  WidgetTester tester,
  _Phone phone,
  String chunk, {
  String paneId = 'wJ:p2',
}) async {
  phone.socket.msg(<String, dynamic>{
    'kind': 'herdr_pane_output',
    'paneId': paneId,
    'revision': 1,
    'format': 'ansi',
    'reset': true,
    'prefix': 0,
    'chunk': chunk,
  });
  await tester.pumpAndSettle();
}

/// A phone in portrait, in logical pixels.
void _phoneScreen(
  WidgetTester tester, {
  Size size = const Size(360, 780),
  double rightInset = 0,
}) {
  tester.view.physicalSize = Size(size.width * 3, size.height * 3);
  tester.view.devicePixelRatio = 3;
  if (rightInset > 0) {
    tester.view.padding = FakeViewPadding(right: rightInset * 3);
  }
  addTearDown(tester.view.reset);
}

Terminal _terminal(WidgetTester tester) =>
    tester.state<TerminalViewState>(find.byType(TerminalView)).widget.terminal;

/// Every row of the emulator, scrollback included.
List<String> _rows(Terminal terminal) => <String>[
  for (var i = 0; i < terminal.buffer.height; i += 1)
    terminal.buffer.lines[i].getText(),
];

/// All visible characters, whitespace removed.
///
/// A reflowed screen breaks lines where the desktop did not, so the *only*
/// position-independent statement a test can make about "nothing was lost, in
/// order" is that the non-space characters are equal to the source's.
String _squeeze(String text) => text.replaceAll(RegExp(r'\s+'), '');

/// Focuses the terminal the way a user does: by tapping the text.
Future<void> _tapTerminal(WidgetTester tester) async {
  await tester.tap(find.byType(TerminalView));
  await tester.pumpAndSettle();
  // xterm arms a 300 ms double-tap timer on tap-up; letting it expire keeps it
  // from surfacing as a pending timer in the next test.
  await tester.pump(const Duration(milliseconds: 350));
  expect(
    tester.testTextInput.hasAnyClients,
    isTrue,
    reason: 'tapping the terminal must attach the soft keyboard',
  );
}

/// Types [text] through the IME channel, sentinel included.
void _ime(WidgetTester tester, String text) {
  tester.testTextInput.updateEditingValue(
    TextEditingValue(
      text: '  $text',
      selection: TextSelection.collapsed(offset: 2 + text.length),
    ),
  );
}

/// A delete as the IME reports it: shorter than the sentinel, no text.
void _imeBackspace(WidgetTester tester) {
  tester.testTextInput.updateEditingValue(
    const TextEditingValue(text: '', selection: TextSelection.collapsed(offset: 0)),
  );
}

void main() {
  // -------------------------------------------------------------------------
  // Reading the desktop screen on a phone
  // -------------------------------------------------------------------------

  group('reading a pane on a phone', () {
    testWidgets('a desktop-width line is fully readable, in order, after the '
        'phone wrap', (tester) async {
      _phoneScreen(tester);
      final phone = await _phone(tester);

      // ~22 cells per token, 15 tokens: far wider than a portrait phone, with a
      // unique marker at every step so an out-of-order or dropped row is caught
      // rather than merely "the tail is there".
      final source =
          '${<String>[for (var i = 0; i < 15; i += 1) 'M$i-${'a' * 18}'].join(' ')} '
          '<RIGHT-END>';
      await _screen(tester, phone, '$source\r\nLAST-MARKER\r\n');

      final terminal = _terminal(tester);
      expect(
        terminal.viewWidth,
        lessThan(displayWidth(source)),
        reason: 'the line must actually be wider than the phone grid',
      );

      final screen = _rows(terminal).join('\n');
      expect(
        _squeeze(screen),
        _squeeze('${source}LAST-MARKER'),
        reason: 'every character of the desktop line is on screen, in order',
      );
      expect(screen, contains('<RIGHT-END>'));

      // A double-width glyph or a cell too many would be clipped by the painted
      // box rather than reflowed. Both insets are deducted: the box is what the
      // user sees, and the right inset is as unavailable as the left one.
      final render = tester
          .state<TerminalViewState>(find.byType(TerminalView))
          .renderTerminal;
      expect(
        render.padding.left + terminal.viewWidth * render.cellSize.width,
        lessThanOrEqualTo(render.size.width - render.padding.right + 0.01),
        reason: 'the last column plus both insets must fit inside the painted box',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('Chinese text wraps without splitting a glyph and without '
        'losing the tail', (tester) async {
      _phoneScreen(tester, size: const Size(400, 900), rightInset: 24);
      final phone = await _phone(tester);

      final source = '${'中文可读测试' * 12}中文尾标';
      await _screen(tester, phone, '$source\r\nLAST-MARKER\r\n');

      final terminal = _terminal(tester);
      final rows = _rows(terminal);
      for (final row in rows) {
        expect(
          displayWidth(row),
          lessThanOrEqualTo(terminal.viewWidth),
          reason: 'a row wider than the grid means a glyph was pushed off the edge',
        );
      }
      expect(
        _squeeze(rows.join('\n')),
        _squeeze('${source}LAST-MARKER'),
        reason: 'no Chinese character is dropped at a wrap boundary',
      );

      // Cell-level proof, not a string comparison: a double-width glyph occupies a
      // lead cell of width 2 **and** a continuation cell of width 0 on the *same*
      // row. A glyph split across the wrap would leave an orphan continuation at
      // column 0 of the next row, and a glyph at the row edge would have a lead
      // cell with no continuation behind it. Neither is visible in the text.
      var wide = 0;
      for (var r = 0; r < terminal.buffer.height; r += 1) {
        final line = terminal.buffer.lines[r];
        expect(
          line.length,
          lessThanOrEqualTo(terminal.viewWidth),
          reason: 'row $r spans more cells than the grid',
        );
        if (line.length == 0) continue;
        // A blank row is padding from `eraseDisplay`, and its cells have no width
        // at all; the orphan rule only means something for a row with glyphs in it.
        if (line.getText().trim().isEmpty) continue;
        expect(
          line.getWidth(0),
          isNot(0),
          reason: 'row $r starts with a continuation cell: a glyph was split',
        );
        for (var c = 0; c < line.length; c += 1) {
          if (line.getWidth(c) != 2) continue;
          wide += 1;
          expect(
            c + 1,
            lessThan(line.length),
            reason: 'wide glyph at row $r col $c has no continuation cell',
          );
          expect(
            line.getWidth(c + 1),
            0,
            reason:
                'the cell after the wide glyph at row $r col $c is not its '
                'continuation, so the glyph is not painted across two cells',
          );
        }
      }
      // 6 characters x 12 repetitions + a 4-character tail: every one of them must
      // hold a lead cell, so none was dropped or folded into its neighbour.
      expect(wide, 76, reason: 'every Chinese character holds a double-width cell');

      // A double-width glyph needs two cells; the grid must leave the last column
      // inside the box or the final character of a row is cut in half.
      final render = tester
          .state<TerminalViewState>(find.byType(TerminalView))
          .renderTerminal;
      expect(
        render.padding.left + terminal.viewWidth * render.cellSize.width,
        lessThanOrEqualTo(render.size.width - render.padding.right + 0.01),
        reason: 'the last column plus both insets must fit inside the painted box',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('opening the keyboard costs no content: the whole screen '
        'survives the reflow', (tester) async {
      _phoneScreen(tester, size: const Size(400, 900));
      final phone = await _phone(tester);

      final rows = <String>[
        'FIRST-ROW',
        for (var i = 0; i < 58; i += 1) 'body-$i-${'x' * 60}',
        'LAST-ROW',
      ];
      await _screen(tester, phone, '${rows.join('\r\n')}\r\n');
      // Twice: the first pass lays out the placeholder grid and the replay is
      // posted after that frame.
      await tester.pumpAndSettle();

      String snapshot(String when) {
        final text = _squeeze(_rows(_terminal(tester)).join('\n'));
        expect(text, isNotEmpty, reason: '$when: the screen still has content');
        return text;
      }

      final tall = snapshot('before the keyboard');
      expect(tall, contains('FIRST-ROW'));
      expect(tall, contains('LAST-ROW'));

      // Keyboard up: the pane gives up more than half its height.
      tester.view.physicalSize = const Size(400 * 3, 380 * 3);
      await tester.pumpAndSettle();
      expect(
        snapshot('with the keyboard up'),
        tall,
        reason: 'shrinking the grid must reflow, not truncate, the screen',
      );

      tester.view.physicalSize = const Size(400 * 3, 900 * 3);
      await tester.pumpAndSettle();
      expect(
        snapshot('after the keyboard closed'),
        tall,
        reason: 'closing the keyboard must restore the same screen',
      );
    });
  });

  // -------------------------------------------------------------------------
  // Typing into the pane
  // -------------------------------------------------------------------------

  group('typing into a pane', () {
    testWidgets('a tap is the only focus step: IME text, Enter, backspace and '
        'the aux keys arrive as the bytes a PC would send', (tester) async {
      _phoneScreen(tester);
      final phone = await _phone(tester);
      await _screen(tester, phone, r'PS D:\> ');
      await _tapTerminal(tester);

      _ime(tester, '你好 世界 abc ');
      await tester.pumpAndSettle();
      expect(
        phone.writes.single,
        (paneId: 'wJ:p2', text: '你好 世界 abc '),
        reason: 'spaces at both ends are part of what the user typed',
      );

      _ime(tester, '\n');
      await tester.pumpAndSettle();
      expect(phone.writes.last.text, '\r', reason: 'the IME Return submits');

      _imeBackspace(tester);
      await tester.pumpAndSettle();
      expect(phone.writes.last.text, '\x7f', reason: 'backspace is DEL, not ^H');

      // Terminal keys a phone keyboard cannot produce. The row scrolls, so on a
      // portrait phone the tail is reached by swiping it — the same gesture a
      // user makes — and no key is unreachable.
      final keyRow = find.ancestor(
        of: find.text('Esc'),
        matching: find.byType(ListView),
      );
      Future<void> press(String label) async {
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
        expect(
          tester.testTextInput.hasAnyClients,
          isTrue,
          reason: 'tapping "$label" must not dismiss the keyboard',
        );
      }

      await press('Esc');
      await press('Tab');
      await press('←');
      await tester.drag(keyRow, const Offset(-320, 0));
      await tester.pumpAndSettle();
      await press('Ctrl-C');
      await press('回车');
      expect(
        phone.writes.map((w) => w.text).skip(3).toList(),
        <String>['\x1b', '\t', '\x1b[D', '\x03', '\r'],
      );
      expect(
        phone.writes.every((w) => w.paneId == 'wJ:p2'),
        isTrue,
        reason: 'every byte targets the pane on screen',
      );
      expect(
        phone.socket.requests.where((r) => r['type'] == 'terminal_resize'),
        isEmpty,
        reason: 'phone geometry must never resize the desktop pane',
      );
    });

    testWidgets('nothing is echoed locally: the screen stays the desktop screen',
        (tester) async {
      _phoneScreen(tester);
      final phone = await _phone(tester);
      await _screen(tester, phone, r'PS D:\> ');
      await _tapTerminal(tester);

      _ime(tester, 'not-accepted-yet');
      await tester.pumpAndSettle();

      expect(phone.writes, hasLength(1));
      expect(
        _rows(_terminal(tester)).join('\n'),
        isNot(contains('not-accepted-yet')),
        reason: 'showing a guess would display text the PC never accepted',
      );
      expect(phone.herdr.paneText('wJ:p2'), r'PS D:\> ');
    });
  });

  // -------------------------------------------------------------------------
  // Switching input target
  // -------------------------------------------------------------------------

  group('switching the input target', () {
    testWidgets('each keystroke lands in the pane that was on screen when it was '
        'typed, across a round trip', (tester) async {
      // Wide enough for both chips to be hittable without scrolling.
      tester.view.physicalSize = const Size(1400, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final phone = await _phone(tester, asScreen: true);
      await _screen(tester, phone, 'shell screen');
      await _screen(tester, phone, 'pi screen', paneId: 'wJ:p3');

      await _tapTerminal(tester);
      _ime(tester, 'shell-1');
      await tester.pumpAndSettle();

      // Tap the other pane's chip, the way the pane row above the terminal does.
      await tester.tap(find.widgetWithText(RawChip, 'pi'));
      await tester.pumpAndSettle();
      expect(
        _rows(_terminal(tester)).join('\n'),
        contains('pi screen'),
        reason: 'the terminal follows the chip the user tapped',
      );
      expect(
        tester.testTextInput.hasAnyClients,
        isTrue,
        reason: 'switching panes must not cost the user their keyboard',
      );
      _ime(tester, 'pi-1');
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(RawChip, 'shell'));
      await tester.pumpAndSettle();
      expect(_rows(_terminal(tester)).join('\n'), contains('shell screen'));
      _ime(tester, 'shell-2');
      await tester.pumpAndSettle();

      // Per-pane streams: correct bytes, correct order, no drift, no loss.
      expect(phone.typedInto('wJ:p2'), 'shell-1shell-2');
      expect(phone.typedInto('wJ:p3'), 'pi-1');
      expect(
        phone.writes.map((w) => w.paneId).toList(),
        <String>['wJ:p2', 'wJ:p3', 'wJ:p2'],
      );
      expect(
        phone.herdr.watchedPaneId,
        'wJ:p2',
        reason: 'the stream ends up on the pane the user returned to',
      );
    });

    testWidgets('a write that fails says which pane it was for and is not '
        'retried', (tester) async {
      _phoneScreen(tester);
      final phone = await _phone(
        tester,
        sockets: <FakeSocket>[
          _agentSocket(sendError: 'herdr_failed:pane_not_found:面板不存在或已关闭（wJ:p2）'),
        ],
      );
      await _tapTerminal(tester);

      _ime(tester, 'goes nowhere');
      await tester.pumpAndSettle();

      expect(find.textContaining('发送到 wJ:p2 失败'), findsOneWidget);
      expect(find.textContaining('不会自动重发'), findsOneWidget);
      expect(
        phone.writes,
        hasLength(1),
        reason: 'a broken ordered stream must not be replayed',
      );
    });
  });

  // -------------------------------------------------------------------------
  // Losing and regaining the link
  // -------------------------------------------------------------------------

  group('a dropped link', () {
    testWidgets('is survivable: the user is told, the swallowed input is not '
        'replayed, and typing works again after the reconnect', (tester) async {
      _phoneScreen(tester);
      // The second link answers immediately; the first is slow on purpose, so a
      // keystroke is still in flight when it dies — that is the case where the
      // user's typing can be lost without telling them.
      final second = _agentSocket();
      final phone = await _phone(
        tester,
        sockets: <FakeSocket>[
          _agentSocket(sendDelayMs: 4000),
          second,
        ],
      );
      await _screen(tester, phone, 'before the drop');
      await _tapTerminal(tester);

      final deadLink = phone.sockets.first;

      // A keystroke is in flight when the link dies, so the queue is non-empty.
      _ime(tester, 'lost-text');
      await tester.pump();
      deadLink.drop();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();

      // The write was already on the wire when the link died, so the app reports
      // it as a failed send that names the pane — which is the more useful
      // message — rather than the generic "the link dropped" strip that covers
      // input still sitting in the queue. Either way the user is told the bytes
      // did not arrive and will not be resent.
      final losses = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data)
          .whereType<String>()
          .where((t) => t.contains('不会自动重发'))
          .toList();
      expect(losses, hasLength(1), reason: 'the user must be told once');
      expect(
        losses.single,
        contains('wJ:p2'),
        reason: 'the notice must say which pane the input was for',
      );
      // While the link is down, typing is paused, and xterm drops its text-input
      // client with it: an IME connection with nowhere to write is not kept open.
      // The point is that the keys are refused, not silently swallowed.
      expect(
        tester.testTextInput.hasAnyClients,
        isFalse,
        reason: 'typing is paused while the PC is unreachable',
      );
      expect(
        _rows(_terminal(tester)).join('\n'),
        contains('before the drop'),
        reason: 'the last screen stays on the phone and stays readable',
      );
      final lostOnFirst = _squeeze(
        deadLink.requests
            .where((r) => r['type'] == 'herdr_send_text')
            .map((r) => '${r['text']}')
            .join(),
      );

      // Come back on a second link. `reconnectNow` skips the backoff wait, but if
      // it lands while the dead socket is still being torn down it is a no-op, so
      // the clock is advanced far enough for the retry timer as well — otherwise
      // the test would depend on which of the two won.
      phone.remote.reconnectNow();
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(phone.remote.isOnline, isTrue, reason: 'the link is restored');

      // The desktop forgot the watch when the old connection went away, so the
      // pane has to be re-subscribed or the screen would stay silent for ever.
      expect(
        second.requests.where((r) => r['type'] == 'herdr_watch').map((r) => r['paneId']),
        contains('wJ:p2'),
      );
      expect(
        second.requests.where((r) => r['type'] == 'herdr_send_text'),
        isEmpty,
        reason: 'input typed into the dead link must not be replayed',
      );

      // The user taps the pane again and is back to typing.
      await _tapTerminal(tester);
      _ime(tester, 'after');
      await tester.pumpAndSettle();
      expect(phone.typedInto('wJ:p2'), 'after');
      expect(
        phone.typedInto('wJ:p2'),
        isNot(contains('lost-text')),
        reason: 'stale typing must never reach the reconnected pane',
      );
      // Whatever did reach the dead link is exactly what the notice covers.
      expect(lostOnFirst, isNot(contains('after')));
      expect(
        find.textContaining('不会自动重发'),
        findsNothing,
        reason: 'a delivered keystroke clears the loss notice',
      );

      // The dead link's reply timer is still scheduled; let it expire so the
      // harness does not report it as a leaked timer.
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('pauses input while offline instead of silently swallowing keys',
        (tester) async {
      _phoneScreen(tester);
      final phone = await _phone(tester);
      await _screen(tester, phone, 'still readable');
      await _tapTerminal(tester);

      phone.socket.drop();
      await tester.pumpAndSettle();

      expect(
        find.textContaining('电脑未连接'),
        findsOneWidget,
        reason: 'the status line explains why typing does nothing',
      );
      // The last known screen stays on the phone and stays readable.
      expect(_rows(_terminal(tester)).join('\n'), contains('still readable'));

      _ime(tester, 'ignored');
      await tester.pumpAndSettle();
      expect(phone.writes, isEmpty);

      // The reconnect backoff is a `Future.delayed` that cannot be cancelled, so
      // the controller is disposed and the wait is allowed to expire before the
      // test ends; otherwise the harness reports a pending timer.
      phone.dispose();
      await tester.pump(const Duration(seconds: 40));
    });
  });
}
