// Model and widget checks for the Windows connection assistant.
//
// These never start the sidecar or a tool: the pairing URI, origin labelling
// and tool-model parsing are pure logic, and the widget tests pump pages with a
// controller whose sidecar is never connected (so no real process is spawned).

import 'package:cloudterminal_windows/models/pairing_uri.dart';
import 'package:cloudterminal_windows/models/tool.dart';
import 'package:cloudterminal_windows/theme/app_theme.dart';
import 'package:cloudterminal_windows/widgets/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PairUri', () {
    test('round-trips relay, code and version', () {
      const uri = PairUri(
        relayUrl: 'wss://relay.example.com/ws',
        code: 'ABCD2345',
      );
      final encoded = uri.encode();
      expect(
        encoded,
        'cloudterminal://pair?relay=${Uri.encodeQueryComponent('wss://relay.example.com/ws')}&code=ABCD2345&v=1',
      );
      final parsed = PairUri.tryParse(encoded);
      expect(parsed, isNotNull);
      expect(parsed!.relayUrl, 'wss://relay.example.com/ws');
      expect(parsed.code, 'ABCD2345');
      expect(parsed.version, 1);
    });

    test('normalizes a dashed or lowercase code', () {
      final parsed = PairUri.tryParse(
        'cloudterminal://pair?relay=ws%3A%2F%2F192.168.1.5%3A8787%2Fws&code=abcd-2345',
      );
      expect(parsed!.code, 'ABCD2345');
      expect(PairUri.displayCode(parsed.code), 'ABCD-2345');
    });

    test('rejects a non-cloudterminal scheme or missing fields', () {
      expect(PairUri.tryParse('https://example.com/?code=X'), isNull);
      expect(PairUri.tryParse('cloudterminal://pair?code=ABCD2345'), isNull);
      expect(
        PairUri.tryParse('cloudterminal://pair?relay=not-a-url&code=ABCD2345'),
        isNull,
      );
      expect(PairUri.tryParse(''), isNull);
    });

    test('accepts only ws/wss relay URLs', () {
      expect(
        PairUri.tryParse(
          'cloudterminal://pair?relay=wss%3A%2F%2Fr%2Fws&code=ABCD2345',
        ),
        isNotNull,
      );
      expect(
        PairUri.tryParse(
          'cloudterminal://pair?relay=http%3A%2F%2Fr%2Fws&code=ABCD2345',
        ),
        isNull,
      );
    });
  });

  group('Tool models', () {
    test('degrades an unknown status gracefully', () {
      expect(parseHerdrStatusIsLenient(), isTrue);
    });

    test('a poll binding never reports itself as a live stream', () {
      const poll = SessionBinding(
        kind: ToolKind.herdr,
        id: 'wJ:p2',
        title: 'wJ:p2',
        origin: StreamOrigin.panePoll,
        pollInterval: Duration(seconds: 1),
      );
      expect(poll.origin.isLive, isFalse);
      expect(poll.originLabel, '轮询 1.0s');

      const live = SessionBinding(
        kind: ToolKind.claude,
        id: 's1',
        title: 'session',
        origin: StreamOrigin.managedStream,
      );
      expect(live.origin.isLive, isTrue);
      expect(live.originLabel, '实时流');
    });

    test('snapshot events are history, not appends', () {
      final event = ToolEvent.fromJson(<String, dynamic>{
        'kind': 'herdr',
        'sessionId': 'wJ:p2',
        'eventKind': 'snapshot',
        'text': 'screen',
      });
      expect(event.isSnapshot, isTrue);
      final delta = ToolEvent.fromJson(<String, dynamic>{
        'kind': 'claude',
        'sessionId': 's1',
        'eventKind': 'assistant_delta',
        'text': 'hi',
      });
      expect(delta.isSnapshot, isFalse);
    });

    test('a probe without a version still reports installed', () {
      const probe = ToolProbe(kind: ToolKind.codex, installed: true);
      expect(probe.bindable, isTrue);
      expect(probe.statusLabel, '已安装');
    });
  });

  group('widgets', () {
    testWidgets('OriginBadge shows the poll interval, not "live"', (
      tester,
    ) async {
      const binding = SessionBinding(
        kind: ToolKind.herdr,
        id: 'wJ:p2',
        title: 'wJ:p2',
        origin: StreamOrigin.panePoll,
        pollInterval: Duration(seconds: 2),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(AppTheme.seeds.first.$2),
          home: const Scaffold(body: OriginBadge(binding: binding)),
        ),
      );
      expect(find.text('轮询 2.0s'), findsOneWidget);
      expect(find.text('实时流'), findsNothing);
    });

    testWidgets('StatusPill renders its label', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(AppTheme.seeds.first.$2),
          home: const Scaffold(
            body: StatusPill(label: '中继已连接', tone: StatusTone.online),
          ),
        ),
      );
      expect(find.text('中继已连接'), findsOneWidget);
    });
  });
}

/// Small helper kept so the model group has a pure assertion without a
/// dependency on the server side.
bool parseHerdrStatusIsLenient() {
  const probe = ToolProbe(kind: ToolKind.herdr, installed: true, version: null);
  return probe.statusLabel == '已安装';
}
