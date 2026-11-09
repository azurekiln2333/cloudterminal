import 'dart:async';

import 'package:cloudterminal/screens/herdr_terminal_screen.dart';
import 'package:cloudterminal/state/appearance.dart';
import 'package:cloudterminal/state/app_store.dart';
import 'package:cloudterminal/state/herdr_controller.dart';
import 'package:cloudterminal/state/remote_controller.dart';
import 'package:cloudterminal/screens/home_screen.dart';
import 'package:cloudterminal/theme/app_theme.dart';
import 'package:cloudterminal/widgets/herdr_terminal.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

import 'support/fake_relay.dart';
import 'terminal_test.dart' show controllerFor;

// ---------------------------------------------------------------------------
// Fixtures — shapes copied from the real agent replies
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

/// Scripted agent that answers only what this file needs.
///
/// Self-contained on purpose: `test/herdr_test.dart` is owned by another worker,
/// so nothing here imports its private helpers.
FakeSocket _scriptSocket({
  List<Map<String, dynamic>>? panes,
  String outputText = '',
  int sendDelayMs = 0,
  String? sendError,
  /// Whether the agent advertises `herdr_paste`. A legacy agent does not, and the
  /// controller must refuse the clipboard rather than fall back to raw keystrokes.
  bool pasteCapable = true,
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

    switch (data['type']) {
      case 'herdr_send_text':
        reply(() {
          if (sendError != null) {
            s.msg(<String, dynamic>{
              'kind': 'error',
              'id': id,
              'message': sendError,
            });
            return;
          }
          s.msg(<String, dynamic>{'kind': 'herdr_result', 'id': id});
        });
      default:
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
                'capabilities': <String>[
                  'terminal',
                  'herdr',
                  if (pasteCapable) 'herdr_paste',
                ],
                'herdr': _availability(),
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
                'availability': _availability(),
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
    }
  };
  return socket;
}

/// A mounted pane plus the controllers behind it.
class _Harness {
  _Harness(this.socket, this.remote, this.herdr, this.paneId);

  final FakeSocket socket;
  final RemoteController remote;
  final HerdrController herdr;
  final String paneId;

  bool _disposed = false;

  /// Every `herdr_send_text` the app put on the wire, in order.
  ///
  /// [paste] is the clipboard-intent flag as the wire carried it: absent from the
  /// JSON unless the widget asked for a paste, which is what keeps ordinary typed
  /// input byte-for-byte as before.
  List<({String paneId, String text, bool paste})> get writes =>
      <({String paneId, String text, bool paste})>[
        for (final r in socket.requests)
          if (r['type'] == 'herdr_send_text')
            (
              paneId: r['paneId'] as String,
              text: r['text'] as String,
              paste: r['paste'] == true,
            ),
      ];

  /// Idempotent so a test can dispose early and let the reconnect backoff expire
  /// without a pending timer, and the tear-down stays a no-op afterwards.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    herdr.dispose();
    remote.dispose();
  }
}

/// Installs a clipboard mock and returns the texts the app *wrote*.
///
/// [read] is what `Clipboard.getData` returns; [readDelay] makes the read resolve
/// later so a test can interleave another action with it.
List<String> _mockClipboard(
  WidgetTester tester, {
  String read = '',
  Duration? readDelay,
}) {
  final writes = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      switch (call.method) {
        case 'Clipboard.getData':
          if (readDelay != null) await Future<void>.delayed(readDelay);
          return <String, dynamic>{'text': read};
        case 'Clipboard.setData':
          final args = call.arguments as Map<Object?, Object?>;
          writes.add('${args['text']}');
          return null;
      }
      return null;
    },
  );
  addTearDown(() {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    );
  });
  return writes;
}

/// Types [text] through the soft-keyboard / IME channel.
///
/// xterm's text-input client keeps a two-space sentinel editing value (that is how
/// it detects a backspace on platforms whose IME only reports a shorter value), and
/// the client computes the delta against it, so a realistic update carries the
/// sentinel plus the new text. Driving the real channel is what proves the IME path
/// works; calling `terminal.textInput` directly would not exercise it.
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

Future<_Harness> _pumpTerminal(
  WidgetTester tester, {
  String paneId = 'wJ:p2',
  String outputText = 'real screen text',
  bool asScreen = false,
  int sendDelayMs = 0,
  String? sendError,
  bool pasteCapable = true,
}) async {
  final socket = _scriptSocket(
    outputText: outputText,
    sendDelayMs: sendDelayMs,
    sendError: sendError,
    pasteCapable: pasteCapable,
  );
  final remote = await controllerFor(socket);
  await tester.pump();
  final herdr = HerdrController(remote);
  final harness = _Harness(socket, remote, herdr, paneId);
  addTearDown(harness.dispose);
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
    // No HerdrTerminalScreen: the widget is mounted directly so a pane switch can
    // be a rebuild rather than a navigation.
    herdr.watchPane(paneId, explicit: true);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(AppTheme.seeds.first.color),
        home: Scaffold(
          body: HerdrTerminal(controller: remote, herdr: herdr, paneId: paneId),
        ),
      ),
    );
  }
  await tester.pumpAndSettle();
  return harness;
}

/// Focuses the terminal the way a user does: by tapping it.
Future<void> _tapTerminal(WidgetTester tester) async {
  await tester.tap(find.byType(TerminalView));
  await tester.pumpAndSettle();
  // xterm's gesture detector arms a 300 ms double-tap timer on tap-up; letting it
  // elapse keeps it from leaking into the next test as a pending timer.
  await tester.pump(const Duration(milliseconds: 350));
  expect(
    tester.testTextInput.hasAnyClients,
    isTrue,
    reason: 'tapping the terminal must attach the soft keyboard',
  );
}

void main() {
  // -------------------------------------------------------------------------
  // Outbound queue
  // -------------------------------------------------------------------------

  group('HerdrPaneInput', () {
    test('sends strictly in order, one await at a time', () async {
      final sent = <String>[];
      var concurrent = 0;
      var peak = 0;
      final input = HerdrPaneInput(
        send: (paneId, data, {bool paste = false}) async {
          concurrent += 1;
          peak = concurrent > peak ? concurrent : peak;
          await Future<void>.delayed(const Duration(milliseconds: 1));
          sent.add('$paneId:$data');
          concurrent -= 1;
        },
      );
      addTearDown(input.dispose);

      input.addText('wJ:p2', 'a');
      input.addText('wJ:p3', 'b');
      input.addText('wJ:p2', 'c');
      await input.settled;

      expect(sent, <String>['wJ:p2:a', 'wJ:p3:b', 'wJ:p2:c']);
      expect(peak, 1, reason: 'two writes must never overlap');
    });

    test('coalesces consecutive text for one pane but never across panes', () async {
      final sent = <String>[];
      final input = HerdrPaneInput(
        send: (paneId, data, {bool paste = false}) async => sent.add('$paneId:$data'),
      );
      addTearDown(input.dispose);

      // Queued while the first write is still in flight.
      final gate = Completer();
      final blocked = HerdrPaneInput(
        send: (paneId, data, {bool paste = false}) async {
          await gate.future;
          sent.add('$paneId:$data');
        },
      );
      addTearDown(blocked.dispose);
      blocked.addText('wJ:p2', 'l');
      blocked.addText('wJ:p2', 's');
      blocked.addText('wJ:p2', ' ');
      blocked.addText('wJ:p3', 'x');
      blocked.addText('wJ:p2', 'y');
      gate.complete();
      await blocked.settled;

      // The first write was already in flight alone; the rest kept their order and
      // their own target, and only the same-pane run was merged.
      expect(sent, <String>['wJ:p2:l', 'wJ:p2:s ', 'wJ:p3:x', 'wJ:p2:y']);
    });

    test('a pane switch never retargets queued input', () async {
      final sent = <({String paneId, String text})>[];
      final gate = Completer();
      final input = HerdrPaneInput(
        send: (paneId, data, {bool paste = false}) async {
          await gate.future;
          sent.add((paneId: paneId, text: data));
        },
      );
      addTearDown(input.dispose);

      input.addText('wJ:p2', 'ls');
      input.addText('wJ:p2', '\r');
      // The user switches to another pane; nothing about the queued writes changes.
      input.addText('wJ:p3', 'pwd');
      gate.complete();
      await input.settled;

      // 'ls' was already in flight, so only the trailing '\r' could coalesce; the
      // point of the assertion is the target, which never becomes 'wJ:p3'.
      expect(sent, <({String paneId, String text})>[
        (paneId: 'wJ:p2', text: 'ls'),
        (paneId: 'wJ:p2', text: '\r'),
        (paneId: 'wJ:p3', text: 'pwd'),
      ]);
    });

    test('long input is chunked under the bridge cap', () async {
      final chunks = <String>[];
      final input = HerdrPaneInput(
        maxChunk: 8,
        send: (paneId, data, {bool paste = false}) async => chunks.add(data),
      );
      addTearDown(input.dispose);

      final data = List<String>.generate(30, (i) => String.fromCharCode(97 + i % 26)).join();
      input.addText('wJ:p2', data);
      await input.settled;

      expect(chunks, isNotEmpty);
      expect(chunks.every((c) => c.length <= 8), isTrue);
      expect(chunks.join(), data, reason: 'no character may be lost');
    });

    test('a chunk boundary never splits a surrogate pair', () async {
      final chunks = <String>[];
      final input = HerdrPaneInput(
        // Odd-sized chunks are what puts a boundary in the middle of an emoji.
        maxChunk: 3,
        send: (paneId, data, {bool paste = false}) async => chunks.add(data),
      );
      addTearDown(input.dispose);

      // 🚀 is a surrogate pair; 'ab' + 🚀 + 'cd' would split it at offset 3.
      const data = 'ab🚀cd';
      input.addText('wJ:p2', data);
      await input.settled;

      expect(chunks.join(), data);
      for (final chunk in chunks) {
        final first = chunk.codeUnitAt(0);
        final last = chunk.codeUnitAt(chunk.length - 1);
        expect(
          first >= 0xDC00 && first <= 0xDFFF,
          isFalse,
          reason: 'chunk must not start with a low surrogate: $chunk',
        );
        expect(
          last >= 0xD800 && last <= 0xDBFF,
          isFalse,
          reason: 'chunk must not end with a high surrogate: $chunk',
        );
      }
    });

    test('a failure is reported once, never retried, and drops the tail', () async {
      var calls = 0;
      final failures = <HerdrInputFailure>[];
      final input = HerdrPaneInput(
        send: (paneId, data, {bool paste = false}) async {
          calls += 1;
          throw const RemoteException('herdr_failed:pane_not_found:面板不存在或已关闭');
        },
        onFailure: failures.add,
      );
      addTearDown(input.dispose);

      input.addText('wJ:p2', 'ls');
      input.addText('wJ:p3', 'queued');
      await input.settled;

      expect(calls, 1, reason: 'no blind resend');
      expect(failures, hasLength(1));
      expect(failures.single.paneId, 'wJ:p2');
      expect(failures.single.message, contains('面板不存在'));
      expect(input.pending, 0, reason: 'the broken stream is dropped, not replayed');
    });

    test('clear() reports how much input was lost', () async {
      final gate = Completer();
      final sent = <String>[];
      final input = HerdrPaneInput(
        send: (paneId, data, {bool paste = false}) async {
          await gate.future;
          sent.add(data);
        },
      );
      addTearDown(input.dispose);

      input.addText('wJ:p2', 'a');
      input.addText('wJ:p2', 'b');
      expect(input.pending, 1, reason: 'the same-pane run is one entry');
      expect(input.clear(), 1);
      gate.complete();
      await input.settled;
      expect(sent, <String>['a']);
    });

    test('a disowned drain that fails late leaves the new queue alone', () async {
      // The disconnect-then-reconnect race: the write that was in flight when the
      // link dropped only fails *after* the user has already typed again. That old
      // drain must not clear the new queue, must not report a loss the user never
      // had, and must not disturb the drain that replaced it.
      final oldGate = Completer<void>();
      final newGate = Completer<void>();
      final calls = <String>[];
      final failures = <HerdrInputFailure>[];
      late HerdrPaneInput input;
      var call = 0;
      input = HerdrPaneInput(
        send: (paneId, data, {bool paste = false}) async {
          call += 1;
          if (call == 1) {
            calls.add('old:$data');
            await oldGate.future; // the disowned write
            throw const RemoteException('与服务器的连接已断开');
          }
          calls.add('new:$data');
          if (call == 2) await newGate.future; // holds the new drain
        },
        onFailure: failures.add,
      );
      addTearDown(input.dispose);

      input.addText('wJ:p2', 'old');
      await Future<void>.delayed(Duration.zero);
      expect(input.sending, isTrue);

      // Disconnect: the in-flight write is disowned.
      expect(input.clear(), 0);

      // The user types again on the new link, and that drain is held with a tail
      // still queued behind it.
      input.addText('wJ:p2', 'new');
      input.addText('wJ:p2', 'tail');
      await Future<void>.delayed(Duration.zero);
      expect(input.pending, 1, reason: 'the new tail is queued');

      // Now the disowned write fails. It must be ignored entirely.
      oldGate.complete();
      await Future<void>.delayed(Duration.zero);
      expect(failures, isEmpty, reason: 'a stale failure is not a user-visible loss');
      expect(input.pending, 1, reason: 'the new queue must not be cleared');

      // Releasing the new drain delivers what the user actually typed, in order.
      newGate.complete();
      await input.settled;
      expect(calls, <String>['old:old', 'new:new', 'new:tail']);
      expect(failures, isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  // Direct input in the widget
  // -------------------------------------------------------------------------

  group('HerdrTerminal direct input', () {
    testWidgets('there is no separate composer: a tap is the input', (
      tester,
    ) async {
      await _pumpTerminal(tester);

      expect(find.byType(TerminalView), findsOneWidget);
      expect(
        find.byType(TextField),
        findsNothing,
        reason: 'the pane must not grow a second, independent input field',
      );

      await _tapTerminal(tester);
      final state = tester.state<TerminalViewState>(find.byType(TerminalView));
      expect(state.widget.readOnly, isFalse);
    });

    testWidgets('typed text reaches the pane verbatim, spaces and CJK kept', (
      tester,
    ) async {
      final h = await _pumpTerminal(tester);
      await _tapTerminal(tester);

      _ime(tester, '你 好 ');
      await tester.pumpAndSettle();

      expect(h.writes, <({String paneId, String text, bool paste})>[
        (paneId: 'wJ:p2', text: '你 好 ', paste: false),
      ], reason: 'leading/trailing spaces are part of the input');
    });

    testWidgets('nothing is echoed locally: the screen is the desktop screen', (
      tester,
    ) async {
      final h = await _pumpTerminal(tester);
      h.socket.msg(<String, dynamic>{
        'kind': 'herdr_pane_output',
        'paneId': 'wJ:p2',
        'revision': 1,
        'format': 'ansi',
        'reset': true,
        'prefix': 0,
        'chunk': 'PS D:\\> ',
      });
      await tester.pumpAndSettle();
      await _tapTerminal(tester);

      _ime(tester, 'not-there-yet');
      await tester.pumpAndSettle();
      expect(h.writes, hasLength(1));

      final terminal = tester
          .state<TerminalViewState>(find.byType(TerminalView))
          .widget
          .terminal;
      final screen = terminal.buffer.getText();
      expect(
        screen.contains('not-there-yet'),
        isFalse,
        reason: 'local echo would show text the PC never accepted',
      );
      expect(h.herdr.paneText('wJ:p2'), 'PS D:\\> ');
    });

    testWidgets('the IME Return is a carriage return, not a bare newline', (
      tester,
    ) async {
      final h = await _pumpTerminal(tester);
      await _tapTerminal(tester);

      _ime(tester, '\n');
      await tester.pumpAndSettle();

      expect(h.writes.single.text, '\r');
    });

    testWidgets('the soft keyboard backspace sends DEL', (tester) async {
      final h = await _pumpTerminal(tester);
      await _tapTerminal(tester);

      _imeBackspace(tester);
      await tester.pumpAndSettle();

      expect(h.writes.single.text, '\x7f');
    });

    testWidgets('hardware keys encode against the pane modes', (tester) async {
      final h = await _pumpTerminal(tester);
      await _tapTerminal(tester);

      Future<void> key(LogicalKeyboardKey logical) async {
        await tester.sendKeyEvent(logical);
        await tester.pumpAndSettle();
      }

      await key(LogicalKeyboardKey.escape);
      await key(LogicalKeyboardKey.tab);
      await key(LogicalKeyboardKey.enter);
      await key(LogicalKeyboardKey.backspace);
      await key(LogicalKeyboardKey.arrowLeft);
      await key(LogicalKeyboardKey.arrowUp);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      expect(h.writes.map((w) => w.text).toList(), <String>[
        '\x1b', // Esc
        '\t', // Tab
        '\r', // Enter
        '\x7f', // DEL, not ^H
        '\x1b[D', // ←
        '\x1b[A', // ↑
        '\x03', // Ctrl-C
      ]);
      expect(
        h.writes.every((w) => w.paneId == 'wJ:p2'),
        isTrue,
        reason: 'every key targets the watched pane',
      );
    });

    testWidgets('the aux key row sends the same bytes and keeps the IME', (
      tester,
    ) async {
      final h = await _pumpTerminal(tester);
      await _tapTerminal(tester);

      // Each label is unique, so the tap is a real hit test on the button.
      for (final label in <String>['Esc', 'Tab', '回车', '⌫', '←', 'Ctrl-C']) {
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
        expect(
          tester.testTextInput.hasAnyClients,
          isTrue,
          reason: 'tapping "$label" must not dismiss the keyboard',
        );
      }

      expect(h.writes.map((w) => w.text).toList(), <String>[
        '\x1b',
        '\t',
        '\r',
        '\x7f',
        '\x1b[D',
        '\x03',
      ]);
    });
  });

  // -------------------------------------------------------------------------
  // Stream safety
  // -------------------------------------------------------------------------

  group('HerdrTerminal stream safety', () {
    testWidgets('replaying a snapshot never answers its own device queries', (
      tester,
    ) async {
      // `ESC[c` (DA1) and `ESC[6n` (DSR) make the emulator *reply* through
      // `Terminal.onOutput`. Those replies are the phone talking to itself; if they
      // were forwarded the desktop pane would receive DA/DSR answers on every
      // repaint, and in a TUI that shows up as stray characters.
      final h = await _pumpTerminal(tester);
      await _tapTerminal(tester);

      h.socket.msg(<String, dynamic>{
        'kind': 'herdr_pane_output',
        'paneId': 'wJ:p2',
        'revision': 1,
        'format': 'ansi',
        'reset': true,
        'prefix': 0,
        'chunk': 'ready\n\x1b[c\x1b[6n',
      });
      await tester.pumpAndSettle();

      expect(
        h.writes,
        isEmpty,
        reason: 'a repaint must not inject emulator replies into the PC',
      );
    });

    testWidgets('a snapshot with indentation and blank rows still replays', (
      tester,
    ) async {
      final h = await _pumpTerminal(tester);
      h.socket.msg(<String, dynamic>{
        'kind': 'herdr_pane_output',
        'paneId': 'wJ:p2',
        'revision': 1,
        'format': 'ansi',
        'reset': true,
        'prefix': 0,
        'chunk': 'def main():\n    return 1\n\n\nok\n',
      });
      await tester.pumpAndSettle();

      final terminal = tester
          .state<TerminalViewState>(find.byType(TerminalView))
          .widget
          .terminal;
      final screen = terminal.buffer.getText();
      expect(screen, contains('    return 1'), reason: 'indentation survives');
      expect(screen, contains('ok'));
      expect(h.writes, isEmpty);
    });

    testWidgets('a pane switch re-points the stream and keeps the keyboard', (
      tester,
    ) async {
      final h = await _pumpTerminal(tester, sendDelayMs: 40);
      await _tapTerminal(tester);

      _ime(tester, 'a');
      await tester.pump();

      // Switch panes while the first keystroke is still in flight.
      h.herdr.watchPane('wJ:p3', explicit: true);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(AppTheme.seeds.first.color),
          home: Scaffold(
            body: HerdrTerminal(
              controller: h.remote,
              herdr: h.herdr,
              paneId: 'wJ:p3',
            ),
          ),
        ),
      );
      await tester.pump();
      expect(
        tester.testTextInput.hasAnyClients,
        isTrue,
        reason: 'switching panes must not cost the user their keyboard',
      );

      _ime(tester, 'b');
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();

      expect(h.writes, <({String paneId, String text, bool paste})>[
        (paneId: 'wJ:p2', text: 'a', paste: false),
        (paneId: 'wJ:p3', text: 'b', paste: false),
      ], reason: 'input must never drift to whichever pane is now selected');
    });

    testWidgets('a disconnect drops queued input and says so', (tester) async {
      final h = await _pumpTerminal(tester, sendDelayMs: 40);
      await _tapTerminal(tester);

      _ime(tester, 'orphan');
      await tester.pump();
      final before = h.writes.length;

      h.socket.drop();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();

      expect(find.textContaining('不会自动重发'), findsOneWidget);
      expect(
        h.writes.length,
        before,
        reason: 'reconnecting must not replay the lost input',
      );

      // The reconnect backoff is a `Future.delayed` that cannot be cancelled, so
      // the controller is disposed and the wait is allowed to expire before the
      // test ends; otherwise the harness reports a pending timer.
      h.dispose();
      await tester.pump(const Duration(seconds: 40));
    });

    testWidgets('a failed write is visible and not retried', (tester) async {
      final h = await _pumpTerminal(
        tester,
        sendError: 'herdr_failed:pane_not_found:面板不存在或已关闭（wJ:p2）',
      );
      await _tapTerminal(tester);

      _ime(tester, 'ls');
      await tester.pumpAndSettle();

      expect(find.textContaining('不会自动重发'), findsOneWidget);
      expect(
        h.writes.length,
        1,
        reason: 'exactly one attempt, no blind resend',
      );
    });
  });

  // -------------------------------------------------------------------------
  // No PTY dependency
  // -------------------------------------------------------------------------

  group('HerdrTerminalScreen', () {
    testWidgets('opens a pane without creating or subscribing a PTY', (
      tester,
    ) async {
      final h = await _pumpTerminal(tester, asScreen: true, outputText: 'pane content');

      expect(find.byType(TerminalView), findsOneWidget);
      // The app bar names the pane; the pane chip above the terminal repeats it.
      expect(find.text('shell'), findsWidgets);
      expect(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.text('shell'),
        ),
        findsOneWidget,
        reason: 'the app bar identifies the pane',
      );
      expect(
        h.socket.lastRequest('create_terminal'),
        isNull,
        reason: 'reaching a pane must not spawn a terminal on the PC',
      );
      expect(h.socket.lastRequest('subscribe'), isNull);
      expect(h.socket.lastRequest('terminal_input'), isNull);
      expect(h.socket.lastRequest('terminal_resize'), isNull);

      final watch = h.socket.lastRequest('herdr_watch');
      expect(watch?['paneId'], 'wJ:p2');
      expect(
        h.socket.requests.where((r) => r['type'] == 'herdr_send_keys'),
        isEmpty,
        reason: 'keys are not used for typing',
      );
    });

    testWidgets('typing never resizes the desktop pane', (tester) async {
      final h = await _pumpTerminal(tester, asScreen: true);
      await _tapTerminal(tester);

      _ime(tester, 'echo hi');
      await tester.pumpAndSettle();

      expect(h.writes.single.text, 'echo hi');
      expect(
        h.socket.requests.where((r) => r['type'] == 'terminal_resize'),
        isEmpty,
        reason: 'phone geometry must not reach the PC',
      );
      expect(h.socket.lastRequest('herdr_send_keys'), isNull);
    });

    testWidgets('the rows above the terminal can switch panes', (tester) async {
      // The standalone screen is pinned to `widget.paneId` unless it follows the
      // controller's selection, which is what the tab/pane rows set.
      tester.view.physicalSize = const Size(1400, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final h = await _pumpTerminal(tester, asScreen: true);
      h.socket.msg(<String, dynamic>{
        'kind': 'herdr_pane_output',
        'paneId': 'wJ:p3',
        'revision': 1,
        'format': 'ansi',
        'reset': true,
        'prefix': 0,
        'chunk': 'third pane',
      });
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(RawChip, 'pi'));
      await tester.pumpAndSettle();

      final view = tester.widget<TerminalView>(find.byType(TerminalView));
      expect(
        view.terminal.buffer.getText(),
        contains('third pane'),
        reason: 'the terminal follows the chip, not the constructor argument',
      );
      await _tapTerminal(tester);
      _ime(tester, 'x');
      await tester.pumpAndSettle();
      expect(
        h.writes.last.paneId,
        'wJ:p3',
        reason: 'input follows the visible pane',
      );
    });
    testWidgets('an authoritatively closed pane stops accepting input', (
      tester,
    ) async {
      final h = await _pumpTerminal(tester, asScreen: true);
      await _tapTerminal(tester);
      _ime(tester, 'a');
      await tester.pumpAndSettle();
      expect(h.writes, hasLength(1), reason: 'typing worked while the pane existed');

      // A complete pane listing for the owning workspace that no longer contains the
      // pane is the authoritative "it is gone" signal.
      h.socket.msg(<String, dynamic>{
        'kind': 'herdr_structure',
        'workspaceId': 'wJ',
        'panes': <Map<String, dynamic>>[
          <String, dynamic>{
            'paneId': 'wJ:p3',
            'workspaceId': 'wJ',
            'tabId': 'wJ:t1',
            'cwd': r'D:\MyNewProjects\cloudterminal',
            'focused': true,
            'terminalTitle': 'π - cloudterminal',
            'name': 'pi',
          },
        ],
      });
      await tester.pumpAndSettle();

      expect(find.textContaining('已不在电脑上'), findsOneWidget);
      expect(
        tester.widget<TerminalView>(find.byType(TerminalView)).readOnly,
        isTrue,
        reason: 'a dead pane id must not be typeable',
      );

      final before = h.writes.length;
      _ime(tester, 'b');
      await tester.pumpAndSettle();
      expect(h.writes.length, before, reason: 'no write to a closed pane');
    });

    testWidgets('a listing for another workspace does not close the pane', (
      tester,
    ) async {
      // Only the pane's *own* workspace can speak about it; a cold or unrelated
      // cache must never look like "the pane was closed".
      final h = await _pumpTerminal(tester, asScreen: true);
      await _tapTerminal(tester);

      h.socket.msg(<String, dynamic>{
        'kind': 'herdr_structure',
        'workspaceId': 'wK',
        'panes': <Map<String, dynamic>>[
          <String, dynamic>{
            'paneId': 'wK:p1',
            'workspaceId': 'wK',
            'tabId': 'wK:t1',
            'cwd': r'C:\other',
            'focused': true,
            'terminalTitle': 'other',
          },
        ],
      });
      await tester.pumpAndSettle();

      expect(find.textContaining('已不在电脑上'), findsNothing);
      expect(
        tester.widget<TerminalView>(find.byType(TerminalView)).readOnly,
        isFalse,
        reason: 'another workspace has no authority over this pane',
      );

      _ime(tester, 'still-works');
      await tester.pumpAndSettle();
      expect(h.writes.single.text, 'still-works');
    });
  });

  group('HerdrTerminal clipboard', () {
    /// A one-word screen so a long press has something to select.
    Future<_Harness> pumpWithWord(WidgetTester tester) async {
      final h = await _pumpTerminal(tester);
      h.socket.msg(<String, dynamic>{
        'kind': 'herdr_pane_output',
        'paneId': 'wJ:p2',
        'revision': 1,
        'format': 'ansi',
        'reset': true,
        'prefix': 0,
        'chunk': 'copyword\r\nsecond line\r\n',
      });
      await tester.pumpAndSettle();
      await tester.pumpAndSettle();
      return h;
    }

    testWidgets('long press then 复制 copies the selection, sends nothing', (
      tester,
    ) async {
      final clipboard = _mockClipboard(tester);
      final h = await pumpWithWord(tester);

      final controller = tester
          .widget<TerminalView>(find.byType(TerminalView))
          .controller!;
      expect(controller.selection, isNull, reason: 'nothing selected yet');
      expect(
        tester.widget<TextButton>(find.widgetWithText(TextButton, '复制')).onPressed,
        isNull,
        reason: 'Copy is disabled without a selection',
      );

      // Long press is the mobile selection gesture the vendored renderer supports.
      // The press must land *on* text: `selectWord` does nothing on an empty cell,
      // and the widget's centre is below a two-line snapshot.
      await tester.longPressAt(
        tester.getTopLeft(find.byType(TerminalView)) + const Offset(6, 6),
      );
      await tester.pumpAndSettle();
      expect(controller.selection, isNotNull, reason: 'long press selects a word');

      final before = h.writes.length;
      await tester.tap(find.widgetWithText(TextButton, '复制'));
      await tester.pumpAndSettle();

      expect(clipboard, hasLength(1));
      expect(clipboard.single, contains('copyword'));
      expect(
        h.writes.length,
        before,
        reason: 'copying is local: no bytes may reach the pane',
      );
      expect(controller.selection, isNull, reason: 'selection is consumed');
    });

    testWidgets('a paste initiated in pane A never lands in pane B', (
      tester,
    ) async {
      // The clipboard read is asynchronous, so a pane switch can happen while it is
      // outstanding. xterm encodes the paste into whatever pane is current, so
      // without an epoch check a path copied for A would be typed into B.
      final clipboard = _mockClipboard(
        tester,
        read: 'D:\\secret-path',
        readDelay: const Duration(milliseconds: 60),
      );
      final h = await _pumpTerminal(tester);
      await _tapTerminal(tester);

      await tester.tap(find.widgetWithText(TextButton, '粘贴'));
      await tester.pump(const Duration(milliseconds: 10));

      // Switch panes while the clipboard read is still outstanding.
      h.herdr.watchPane('wJ:p3', explicit: true);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(AppTheme.seeds.first.color),
          home: Scaffold(
            body: HerdrTerminal(
              controller: h.remote,
              herdr: h.herdr,
              paneId: 'wJ:p3',
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();

      expect(h.writes, isEmpty, reason: 'the paste must be abandoned, not retargeted');
      expect(find.textContaining('粘贴没有送出'), findsOneWidget);
      expect(clipboard, isEmpty, reason: 'nothing was written back either');
      expect(
        tester.testTextInput.hasAnyClients,
        isTrue,
        reason: 'cancelling a paste must not cost the keyboard',
      );
    });

    testWidgets('a paste with no switch reaches the pane it was made in', (
      tester,
    ) async {
      _mockClipboard(tester, read: 'pasted text');
      final h = await _pumpTerminal(tester);
      await _tapTerminal(tester);

      await tester.tap(find.widgetWithText(TextButton, '粘贴'));
      await tester.pumpAndSettle();

      expect(h.writes.single.paneId, 'wJ:p2');
      expect(h.writes.single.text, 'pasted text');
    });

    testWidgets('a clipboard holding only a newline pastes as that newline', (
      tester,
    ) async {
      // The IME's Return is rewritten from LF to CR; the clipboard must not be.
      // A clipboard that is *exactly* one LF is real text (a blank line the user
      // copied), so the paste-context flag is what keeps the two apart.
      _mockClipboard(tester, read: '\n');
      final h = await _pumpTerminal(tester);
      await _tapTerminal(tester);

      await tester.tap(find.widgetWithText(TextButton, '粘贴'));
      await tester.pumpAndSettle();

      expect(h.writes.single.paneId, 'wJ:p2');
      expect(
        h.writes.single.text,
        '\n',
        reason: 'a pasted LF must reach the pane as LF, not be turned into CR',
      );
    });

    testWidgets('the IME Return still becomes CR right after a paste', (
      tester,
    ) async {
      // The flag must be cleared again: a stale `_pasting` would stop every later
      // Return from submitting.
      _mockClipboard(tester, read: 'ls -la');
      final h = await _pumpTerminal(tester);
      await _tapTerminal(tester);

      await tester.tap(find.widgetWithText(TextButton, '粘贴'));
      await tester.pumpAndSettle();
      _ime(tester, '\n');
      await tester.pumpAndSettle();

      expect(h.writes.last.text, '\r');
    });

    testWidgets('a paste outstanding across a disconnect never lands', (
      tester,
    ) async {
      // A disconnect also invalidates a clipboard read in flight: after the link
      // comes back, delivering text the user copied minutes ago would type into a
      // pane whose state they cannot see.
      _mockClipboard(
        tester,
        read: 'stale-text',
        readDelay: const Duration(milliseconds: 60),
      );
      final h = await _pumpTerminal(tester);
      await _tapTerminal(tester);

      await tester.tap(find.widgetWithText(TextButton, '粘贴'));
      await tester.pump(const Duration(milliseconds: 10));
      h.socket.drop();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();

      expect(h.writes, isEmpty);
      expect(find.textContaining('粘贴没有送出'), findsOneWidget);

      h.dispose();
      await tester.pump(const Duration(seconds: 40));
    });

    testWidgets('physical Ctrl+V goes through the guarded paste path', (
      tester,
    ) async {
      // xterm's own `PasteTextIntent` handler calls `Terminal.paste` directly, which
      // would ignore the pane/link guards. The widget replaces that shortcut so the
      // hardware keyboard cannot bypass them.
      _mockClipboard(tester, read: 'phys-paste');
      final h = await _pumpTerminal(tester);
      await _tapTerminal(tester);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      expect(h.writes.single.paneId, 'wJ:p2');
      expect(h.writes.single.text, 'phys-paste');
    });

    testWidgets('physical Ctrl+V is cancelled when the pane switches', (
      tester,
    ) async {
      _mockClipboard(
        tester,
        read: 'phys-stale',
        readDelay: const Duration(milliseconds: 60),
      );
      final h = await _pumpTerminal(tester);
      await _tapTerminal(tester);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump(const Duration(milliseconds: 10));

      h.herdr.watchPane('wJ:p3', explicit: true);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(AppTheme.seeds.first.color),
          home: Scaffold(
            body: HerdrTerminal(
              controller: h.remote,
              herdr: h.herdr,
              paneId: 'wJ:p3',
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();

      expect(h.writes, isEmpty, reason: 'the shortcut must not bypass the guard');
      expect(find.textContaining('粘贴没有送出'), findsOneWidget);
    });
  });

  // -------------------------------------------------------------------------
  // The frame between a selection change and the rebuild
  // -------------------------------------------------------------------------

  // -------------------------------------------------------------------------
  // Clipboard paste intent on the wire
  // -------------------------------------------------------------------------

  group('HerdrTerminal paste intent', () {
    /// Taps 粘贴 and lets the clipboard read and the queue settle.
    Future<void> tapPaste(WidgetTester tester) async {
      await tester.tap(find.widgetWithText(TextButton, '粘贴'));
      await tester.pumpAndSettle();
    }

    testWidgets('a pasted clipboard is flagged as a paste on the wire', (
      tester,
    ) async {
      _mockClipboard(tester, read: 'line one\nline two');
      final h = await _pumpTerminal(tester);
      await _tapTerminal(tester);

      await tapPaste(tester);

      expect(h.writes.single.paneId, 'wJ:p2');
      expect(h.writes.single.text, 'line one\nline two');
      expect(
        h.writes.single.paste,
        isTrue,
        reason:
            'the desktop must be told this is a paste so it can wrap it in the '
            'pane\'s real bracketed-paste mode',
      );
    });

    testWidgets('typed input and keys never carry the paste flag', (
      tester,
    ) async {
      _mockClipboard(tester, read: 'clip');
      final h = await _pumpTerminal(tester);
      await _tapTerminal(tester);

      _ime(tester, 'abc');
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tapPaste(tester);
      _ime(tester, 'def');
      await tester.pumpAndSettle();

      final typed = h.writes.where((w) => w.text != 'clip').toList();
      expect(typed, isNotEmpty);
      expect(
        typed.every((w) => w.paste == false),
        isTrue,
        reason: 'only clipboard-origin writes may claim paste intent',
      );
    });

    testWidgets('a paste and later typing stay separate, in order', (
      tester,
    ) async {
      // A paste must not coalesce with typed input: merging them would hand the
      // keystrokes to the desktop's paste path (and make the paste unmergeable in
      // the other direction). Order is still the user's.
      _mockClipboard(tester, read: 'PASTE');
      final h = await _pumpTerminal(tester);
      await _tapTerminal(tester);

      await tapPaste(tester);
      _ime(tester, 'typed');
      await tester.pumpAndSettle();

      expect(h.writes.length, 2, reason: 'the paste and the typing are two writes');
      expect(
        h.writes[0],
        (paneId: 'wJ:p2', text: 'PASTE', paste: true),
        reason: 'the paste goes first, intact',
      );
      expect(
        h.writes[1],
        (paneId: 'wJ:p2', text: 'typed', paste: false),
        reason: 'typed input follows as raw keys',
      );
    });

    testWidgets('typed input then a paste also stay separate', (
      tester,
    ) async {
      _mockClipboard(tester, read: 'PASTE');
      final h = await _pumpTerminal(tester);
      await _tapTerminal(tester);

      _ime(tester, 'typed');
      await tester.pumpAndSettle();
      await tapPaste(tester);

      expect(h.writes.length, 2);
      expect(h.writes[0].text, 'typed');
      expect(h.writes[0].paste, isFalse);
      expect(h.writes[1].text, 'PASTE');
      expect(h.writes[1].paste, isTrue);
    });

    testWidgets('a newline-only clipboard stays a newline, still flagged paste', (
      tester,
    ) async {
      // The IME's lone LF becomes CR; the clipboard's must not, and it must still
      // be a paste so the desktop can decide what that LF means in the pane.
      _mockClipboard(tester, read: '\n');
      final h = await _pumpTerminal(tester);
      await _tapTerminal(tester);

      await tapPaste(tester);

      expect(h.writes.single.text, '\n', reason: 'pasted LF is not rewritten');
      expect(h.writes.single.paste, isTrue);
    });

    testWidgets('no bracketed-paste markers are ever added by the phone', (
      tester,
    ) async {
      // The client cannot know the pane's real mode, so it must not guess: the
      // markers are the desktop's job. Doubling them would corrupt the paste.
      _mockClipboard(tester, read: 'plain text');
      final h = await _pumpTerminal(tester);
      await _tapTerminal(tester);

      await tapPaste(tester);

      expect(h.writes.single.text, 'plain text');
      expect(h.writes.single.text.contains('\x1b[200~'), isFalse);
      expect(h.writes.single.text.contains('\x1b[201~'), isFalse);
    });

    testWidgets('every chunk of a long paste keeps the paste flag', (
      tester,
    ) async {
      // Longer than HerdrPaneInput.maxChunkChars (8192) so it must be split.
      final long = List<String>.filled(20000, 'x').join();
      _mockClipboard(tester, read: long);
      final h = await _pumpTerminal(tester, sendDelayMs: 1);
      await _tapTerminal(tester);

      await tapPaste(tester);
      await tester.pumpAndSettle();

      expect(
        h.writes.length,
        greaterThan(1),
        reason: 'the paste must be split into several chunks',
      );
      expect(
        h.writes.every((w) => w.paste),
        isTrue,
        reason: 'a chunk without the flag would be typed as keystrokes',
      );
      expect(h.writes.map((w) => w.text).join(), long);
    });

    testWidgets('two pastes do not merge into one request', (tester) async {
      // Each paste keeps its own boundaries so the desktop wraps each separately.
      final h = await _pumpTerminal(tester);
      await _tapTerminal(tester);

      _mockClipboard(tester, read: 'first');
      await tapPaste(tester);
      _mockClipboard(tester, read: 'second');
      await tapPaste(tester);

      expect(h.writes.length, 2);
      expect(h.writes.every((w) => w.paste), isTrue);
      expect(h.writes[0].text, 'first');
      expect(h.writes[1].text, 'second');
    });

    testWidgets('a legacy agent refuses the paste and asks for an update', (
      tester,
    ) async {
      // An old agent ignores unknown fields, so `paste: true` would silently
      // become raw keystrokes. The controller refuses instead — and the failure
      // has to be visible, not a silent drop.
      _mockClipboard(tester, read: 'secret\nlines');
      final h = await _pumpTerminal(tester, pasteCapable: false);
      await _tapTerminal(tester);

      await tapPaste(tester);

      expect(h.writes, isEmpty, reason: 'no raw downgrade is allowed');
      expect(find.textContaining('请更新电脑版'), findsOneWidget);
    });

    testWidgets('typed input still works against a legacy agent', (
      tester,
    ) async {
      final h = await _pumpTerminal(tester, pasteCapable: false);
      await _tapTerminal(tester);

      _ime(tester, 'still fine');
      await tester.pumpAndSettle();

      expect(h.writes.single.text, 'still fine');
      expect(h.writes.single.paste, isFalse);
      expect(find.textContaining('请更新电脑版'), findsNothing);
    });
  });

  group('HerdrTerminal pane transition', () {
    /// Mounts the widget the way SessionScreen does: the owner rebuilds from
    /// `herdr.watchedPaneId`, so the pane id follows the controller.
    Future<_Harness> pumpOwned(WidgetTester tester) async {
      final socket = _scriptSocket(outputText: 'pane screen');
      final remote = await controllerFor(socket);
      await tester.pump();
      final herdr = HerdrController(remote)..watchPane('wJ:p2', explicit: true);
      final harness = _Harness(socket, remote, herdr, 'wJ:p2');
      addTearDown(harness.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(AppTheme.seeds.first.color),
          home: Scaffold(
            body: ListenableBuilder(
              listenable: herdr,
              builder: (context, _) => HerdrTerminal(
                controller: remote,
                herdr: herdr,
                paneId: herdr.watchedPaneId ?? 'wJ:p2',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return harness;
    }

    testWidgets('a key typed before the rebuild never lands in the old pane', (
      tester,
    ) async {
      // `watchPane` notifies synchronously, but the owner only rebuilds on the next
      // frame. In that window the emulator still holds pane A, and forwarding its
      // bytes would type into the pane the user just left.
      final h = await pumpOwned(tester);
      await _tapTerminal(tester);

      h.herdr.watchPane('wJ:p3', explicit: true);
      _ime(tester, 'leak');
      await tester.pumpAndSettle();

      expect(
        h.writes.where((w) => w.paneId == 'wJ:p2'),
        isEmpty,
        reason: 'the old pane must never receive input after the selection moved',
      );
      expect(find.textContaining('面板正在切换'), findsOneWidget);
    });

    testWidgets('input reaches the new pane once the owner has rebuilt', (
      tester,
    ) async {
      final h = await pumpOwned(tester);
      await _tapTerminal(tester);

      h.herdr.watchPane('wJ:p3', explicit: true);
      _ime(tester, 'leak');
      await tester.pumpAndSettle();

      _ime(tester, 'ok');
      await tester.pumpAndSettle();

      expect(h.writes.last.paneId, 'wJ:p3');
      expect(h.writes.last.text, 'ok');
      expect(
        h.writes.where((w) => w.text.contains('leak')),
        isEmpty,
        reason: 'the refused keystroke is dropped, not deferred into the new pane',
      );
    });

    testWidgets('a paste started in the transition window is refused', (
      tester,
    ) async {
      _mockClipboard(tester, read: 'transition-paste');
      final h = await pumpOwned(tester);
      await _tapTerminal(tester);

      h.herdr.watchPane('wJ:p3', explicit: true);
      await tester.tap(find.widgetWithText(TextButton, '粘贴'));
      await tester.pumpAndSettle();

      expect(h.writes, isEmpty);
      expect(find.textContaining('粘贴没有送出'), findsOneWidget);
    });
  });

  // -------------------------------------------------------------------------
  // End to end: the app entry point opens a pane with no PTY
  // -------------------------------------------------------------------------

  group('HomeScreen to pane', () {
    testWidgets('opening a pane from home creates no terminal session', (
      tester,
    ) async {
      // The requirement is about the *product* path, not about the widget: starting
      // at the app's home screen, reaching a pane must not spawn a PTY on the PC.
      tester.view.physicalSize = const Size(420 * 2, 900 * 2);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);

      final socket = _scriptSocket();
      final remote = await controllerFor(socket);
      await tester.pump();
      final appearance = Appearance(AppStore.memory());
      addTearDown(() {
        appearance.dispose();
        remote.dispose();
      });

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(AppTheme.seeds.first.color),
          home: HomeScreen(controller: remote, appearance: appearance),
        ),
      );
      await tester.pumpAndSettle();

      // Drawer -> Herdr destination.
      await tester.tap(find.byIcon(Icons.menu_rounded));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Herdr 工作区'));
      await tester.pumpAndSettle();

      // Workspace -> expand -> pane row. The row is targeted by pane id: the list
      // prefers the terminal title as its label, the id is unambiguous.
      await tester.tap(find.text('cloudterminal').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('wJ:p2'));
      await tester.pumpAndSettle();

      expect(
        find.byType(HerdrTerminalScreen),
        findsOneWidget,
        reason: 'the pane screen is pushed',
      );
      expect(find.byType(TerminalView), findsOneWidget);
      expect(socket.lastRequest('herdr_watch')?['paneId'], 'wJ:p2');
      expect(
        socket.lastRequest('create_terminal'),
        isNull,
        reason: 'reaching a pane must not spawn a terminal on the PC',
      );
      expect(socket.lastRequest('subscribe'), isNull);

      // And the terminal is live, not a read-only picture.
      await tester.tap(find.byType(TerminalView));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 350));
      _ime(tester, 'pwd');
      await tester.pumpAndSettle();
      final writes = <({String paneId, String text})>[
        for (final r in socket.requests)
          if (r['type'] == 'herdr_send_text')
            (paneId: r['paneId'] as String, text: r['text'] as String),
      ];
      expect(writes.last.text, 'pwd');
      expect(writes.last.paneId, 'wJ:p2');
    });
  });

  // -------------------------------------------------------------------------
  // Phone geometry: the patched xterm viewport contract
  // -------------------------------------------------------------------------
  group('HerdrTerminal geometry', () {
    testWidgets('the grid is the phone width and no character is clipped', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360 * 3, 780 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      final h = await _pumpTerminal(tester);
      // 200 characters plus a right-edge sentinel: far wider than any phone.
      final body = '${'a' * 200}<RIGHT-END>';
      h.socket.msg(<String, dynamic>{
        'kind': 'herdr_pane_output',
        'paneId': 'wJ:p2',
        'revision': 1,
        'format': 'ansi',
        'reset': true,
        'prefix': 0,
        'chunk': '$body\r\n',
      });
      await tester.pumpAndSettle();

      final state = tester.state<TerminalViewState>(find.byType(TerminalView));
      final terminal = state.widget.terminal;
      expect(terminal.viewWidth, lessThan(200), reason: 'wrapped at phone width');
      expect(terminal.viewWidth, greaterThan(20));
      final text = terminal.buffer.getText();
      expect(text, contains('a' * 200));
      expect(
        text,
        contains('<RIGHT-END>'),
        reason: 'the right-hand end must be reachable, not clipped',
      );

      // The conservative xterm patch: the last column plus the left inset must fit
      // inside the painted box, or a double-width glyph is cut in half.
      final render = state.renderTerminal;
      expect(
        terminal.viewWidth * render.cellSize.width + render.padding.left,
        lessThanOrEqualTo(render.size.width + 0.01),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('CJK survives the phone-width wrap', (tester) async {
      tester.view.physicalSize = const Size(400 * 3, 900 * 3);
      tester.view.devicePixelRatio = 3;
      tester.view.padding = const FakeViewPadding(right: 24 * 3);
      addTearDown(tester.view.reset);

      final h = await _pumpTerminal(tester);
      h.socket.msg(<String, dynamic>{
        'kind': 'herdr_pane_output',
        'paneId': 'wJ:p2',
        'revision': 1,
        'format': 'ansi',
        'reset': true,
        'prefix': 0,
        'chunk':
            '${'中文可读测试' * 12}中文尾标\r\n'
            'LAST-MARKER\r\n',
      });
      await tester.pumpAndSettle();

      final state = tester.state<TerminalViewState>(find.byType(TerminalView));
      final terminal = state.widget.terminal;
      final text = terminal.buffer.getText();
      expect(text, contains('中文尾标'), reason: 'the CJK tail is not dropped');
      expect(text, contains('LAST-MARKER'));
      final render = state.renderTerminal;
      expect(
        terminal.viewWidth * render.cellSize.width + render.padding.left,
        lessThanOrEqualTo(render.size.width + 0.01),
        reason: 'a double-width glyph must fit inside the painted box',
      );
    });

    testWidgets('a static snapshot survives keyboard height changes', (
      tester,
    ) async {
      // `Terminal.resize` reflows and pops rows, so every refit has to replay the
      // snapshot; there may be no further push to restore what a resize dropped.
      tester.view.physicalSize = const Size(400 * 3, 900 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      final h = await _pumpTerminal(tester);
      final rows = <String>[
        'FIRST-ROW',
        for (var i = 0; i < 58; i += 1) 'body-$i-${'x' * 60}',
        'LAST-ROW',
      ];
      h.socket.msg(<String, dynamic>{
        'kind': 'herdr_pane_output',
        'paneId': 'wJ:p2',
        'revision': 1,
        'format': 'ansi',
        'reset': true,
        'prefix': 0,
        'chunk': '${rows.join('\r\n')}\r\n',
      });
      // Two passes: the first lays out the placeholder grid, and the replay is
      // posted for after that frame.
      await tester.pumpAndSettle();
      await tester.pumpAndSettle();

      void expectBothEnds(String when) {
        final terminal = tester
            .state<TerminalViewState>(find.byType(TerminalView))
            .widget
            .terminal;
        final text = <String>[
          for (var i = 0; i < terminal.buffer.height; i++)
            terminal.buffer.lines[i].getText(),
        ].join('\n');
        expect(text, contains('FIRST-ROW'), reason: '$when: start present');
        expect(text, contains('LAST-ROW'), reason: '$when: end survived');
        for (final probe in <String>['body-0-', 'body-29-', 'body-57-']) {
          expect(text, contains(probe), reason: '$when: $probe retained');
        }
        expect(
          terminal.buffer.scrollBack,
          greaterThan(0),
          reason: '$when: overflow stays as scrollback',
        );
      }

      expectBothEnds('after the first layout');

      // Keyboard up: the pane gives up height, which reflows the buffer.
      tester.view.physicalSize = const Size(400 * 3, 520 * 3);
      await tester.pumpAndSettle();
      expectBothEnds('with the keyboard up');

      tester.view.physicalSize = const Size(400 * 3, 900 * 3);
      await tester.pumpAndSettle();
      expectBothEnds('after the keyboard closed');
    });

    testWidgets('both ends of a long screen are reachable by scrolling', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360 * 3, 700 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      final h = await _pumpTerminal(tester);
      final rows = <String>[
        'TOP-OF-SCREEN',
        for (var i = 0; i < 60; i += 1) 'line-$i-${'y' * 50}',
        'BOTTOM-OF-SCREEN',
      ];
      h.socket.msg(<String, dynamic>{
        'kind': 'herdr_pane_output',
        'paneId': 'wJ:p2',
        'revision': 1,
        'format': 'ansi',
        'reset': true,
        'prefix': 0,
        'chunk': '${rows.join('\r\n')}\r\n',
      });
      await tester.pumpAndSettle();
      await tester.pumpAndSettle();

      final scroll = tester
          .widget<TerminalView>(find.byType(TerminalView))
          .scrollController!;
      expect(
        scroll.position.maxScrollExtent,
        greaterThan(0),
        reason: 'content taller than the viewport must be scrollable',
      );
      // The oldest line is reachable at the top...
      scroll.jumpTo(0);
      await tester.pump();
      expect(scroll.position.pixels, 0);
      // ...and the newest at the bottom, in one continuous scroll range.
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pump();
      expect(scroll.position.pixels, scroll.position.maxScrollExtent);

      final text = tester
          .state<TerminalViewState>(find.byType(TerminalView))
          .widget
          .terminal
          .buffer
          .getText();
      expect(text, contains('TOP-OF-SCREEN'));
      expect(text, contains('BOTTOM-OF-SCREEN'));
    });
  });
}
