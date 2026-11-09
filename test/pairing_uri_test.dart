import 'dart:async';

import 'package:cloudterminal/models/pairing_uri.dart';
import 'package:cloudterminal/net/relay_socket.dart';
import 'package:cloudterminal/state/app_store.dart';
import 'package:cloudterminal/state/remote_controller.dart';
import 'package:flutter_test/flutter_test.dart';

/// A socket that answers the pairing `hello` exactly once and never lets the
/// connection loop reach the network.
///
/// `pairWithCode` subscribes to [frames] *after* sending, so the reply has to
/// be pushed on a microtask: a broadcast stream drops frames emitted while
/// nobody is listening.
class _PairingSocket implements RelaySocket {
  _PairingSocket({this.reply});

  final Map<String, dynamic>? reply;
  final StreamController<Map<String, dynamic>> _in =
      StreamController<Map<String, dynamic>>.broadcast();
  final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];
  bool closed = false;

  @override
  Stream<Map<String, dynamic>> get frames => _in.stream;

  @override
  void send(Map<String, dynamic> frame) {
    sent.add(frame);
    final answer = reply;
    if (answer != null) {
      scheduleMicrotask(() {
        if (!_in.isClosed) _in.add(answer);
      });
    }
  }

  @override
  Future<void> close() async {
    closed = true;
    if (!_in.isClosed) await _in.close();
  }

  @override
  int? get closeCode => closed ? 1000 : null;

  @override
  String? get closeReason => null;
}

const Map<String, dynamic> _pairedReply = <String, dynamic>{
  't': 'paired',
  'agentId': 'a_desktop',
  'secret': 's3cret',
  'name': 'DESKTOP',
};

/// Relay URL to point every payload at in the controller tests.
const String _relay = 'wss://relay.example.com/ws';

String payloadFor(String relay, {String code = 'ABCD2345'}) =>
    'cloudterminal://pair?relay=${Uri.encodeQueryComponent(relay)}'
    '&code=$code&v=1';

void main() {
  group('PairingUri.tryParse / encode', () {
    test('round-trips the canonical payload', () {
      final parsed = PairingUri.tryParse(
        'cloudterminal://pair?relay=wss%3A%2F%2Frelay.example.com%2Fws'
        '&code=ABCD2345&v=1',
      )!;
      expect(parsed.relay, Uri.parse('wss://relay.example.com/ws'));
      expect(parsed.code, 'ABCD2345');
      expect(parsed.version, 1);

      final again = PairingUri.tryParse(parsed.encode())!;
      expect(again.relay, parsed.relay);
      expect(again.code, parsed.code);
      expect(again.version, parsed.version);
      expect(again.encode(), parsed.encode());
    });

    test('round-trips a payload built by encode', () {
      final original = PairingUri(
        relay: Uri.parse('wss://relay.example.com:8443/custom'),
        code: 'Z9Y8X7W6',
      );
      final parsed = PairingUri.tryParse(original.encode())!;
      expect(parsed.relay, original.relay);
      expect(parsed.code, original.code);
      expect(parsed.version, PairingUri.currentVersion);
      expect(parsed.toString(), original.encode());
    });

    test('defaults a missing v to the current version', () {
      final parsed = PairingUri.tryParse(payloadFor(_relay).replaceAll('&v=1', ''))!;
      expect(parsed.version, PairingUri.currentVersion);
    });

    test('normalizes a bare LAN ip:port to ws on /ws', () {
      final parsed = PairingUri.tryParse(
        'cloudterminal://pair?relay=192.168.1.5%3A8787&code=ABCD2345&v=1',
      )!;
      // LAN addresses have no TLS terminator, so they default to plain ws.
      expect(parsed.relay.toString(), 'ws://192.168.1.5:8787/ws');
      expect(parsed.relay.scheme, 'ws');
    });

    test('keeps an explicit port and path, upgrades https to wss', () {
      final lan = PairingUri.tryParse(payloadFor('ws://10.0.0.7:9000/relay'))!;
      expect(lan.relay.toString(), 'ws://10.0.0.7:9000/relay');

      final public = PairingUri.tryParse(payloadFor('https://relay.example.com'))!;
      expect(public.relay.toString(), 'wss://relay.example.com/ws');
    });

    test('drops the cosmetic dash and upper-cases the code', () {
      final parsed = PairingUri.tryParse(payloadFor(_relay, code: 'abcd-2345'))!;
      expect(parsed.code, 'ABCD2345');
    });

    test('accepts a scanner prefix and trailing whitespace', () {
      final parsed = PairingUri.tryParse(
        'content: cloudterminal://pair?relay=wss%3A%2F%2Frelay.example.com%2Fws'
        '&code=ABCD2345&v=1\n',
      )!;
      expect(parsed.relay.toString(), _relay);
      expect(parsed.code, 'ABCD2345');
    });

    test('accepts a label before and prose after on the same line', () {
      final parsed = PairingUri.tryParse(
        'Scan me! cloudterminal://pair?relay=wss%3A%2F%2Frelay.example.com%2Fws'
        '&code=ABCD2345&v=1 thanks',
      )!;
      expect(parsed.relay.toString(), _relay);
    });

    test('returns null for payloads that are not pairing links', () {
      expect(PairingUri.tryParse(null), isNull, reason: 'null input');
      expect(PairingUri.tryParse(''), isNull, reason: 'empty string');
      expect(PairingUri.tryParse('   '), isNull, reason: 'whitespace only');
      expect(PairingUri.tryParse('https://relay.example.com'), isNull);
      expect(
        PairingUri.tryParse('cloudterminal://open?relay=x&code=ABCD2345'),
        isNull,
        reason: 'wrong host',
      );
      expect(
        PairingUri.tryParse('cloudterminal://pair'),
        isNull,
        reason: 'no query at all',
      );
      expect(
        PairingUri.tryParse('cloudterminal://pair?code=ABCD2345&v=1'),
        isNull,
        reason: 'missing relay',
      );
      expect(
        PairingUri.tryParse('cloudterminal://pair?relay=&code=ABCD2345&v=1'),
        isNull,
        reason: 'empty relay',
      );
      expect(
        PairingUri.tryParse('cloudterminal://pair?relay=wss%3A%2F%2Fr%2Fws&v=1'),
        isNull,
        reason: 'missing code',
      );
      expect(
        PairingUri.tryParse('cloudterminal://pair?relay=wss%3A%2F%2Fr%2Fws&code=ABCD234'),
        isNull,
        reason: 'code too short',
      );
      expect(
        PairingUri.tryParse('cloudterminal://pair?relay=wss%3A%2F%2Fr%2Fws&code=ABCD23456'),
        isNull,
        reason: 'code too long',
      );
      expect(
        PairingUri.tryParse('cloudterminal://pair?relay=wss%3A%2F%2Fr%2Fws&code=ABCD2345&v=0'),
        isNull,
        reason: 'unsupported version',
      );
      expect(
        PairingUri.tryParse('cloudterminal://pair?relay=wss%3A%2F%2Fr%2Fws&code=ABCD2345&v=x'),
        isNull,
        reason: 'non-numeric version',
      );
    });

    test('rejects a relay that is not a websocket url', () {
      expect(
        PairingUri.tryParse(payloadFor('ftp://relay.example.com')),
        isNull,
      );
      // A bare path with no host cannot become a relay endpoint.
      expect(PairingUri.tryParse(payloadFor('/just/a/path')), isNull);
    });

    test('normalizePairCode enforces eight alphanumerics', () {
      expect(PairingUri.normalizePairCode('abcd-2345'), 'ABCD2345');
      expect(PairingUri.normalizePairCode('ABCD2345'), 'ABCD2345');
      expect(PairingUri.normalizePairCode(null), isNull);
      expect(PairingUri.normalizePairCode('abcd'), isNull);
      expect(PairingUri.normalizePairCode('ABCD23456'), isNull);
    });
  });

  group('RemoteController.pairWithQr', () {
    test('exchanges the code for credentials', () async {
      final store = AppStore.memory();
      final socket = _PairingSocket(reply: _pairedReply);
      final controller = RemoteController(
        store: store,
        connector: (_) async => socket,
      );
      addTearDown(controller.dispose);

      final result = await controller.pairWithQr(payloadFor(_relay));

      expect(result.status, QrPairStatus.paired);
      expect(result.needsRelayConfirm, isFalse);
      expect(result.relayUrl, _relay);
      expect(result.relayHost, 'relay.example.com');
      expect(controller.pairing?.relayUrl, _relay);
      expect(controller.pairing?.agentId, 'a_desktop');
      expect(controller.pairing?.secret, 's3cret');
      expect(controller.pairing?.name, 'DESKTOP');
      // The normalization survives onto the wire.
      expect(
        socket.sent.single,
        containsPair('code', 'ABCD2345'),
      );
    });

    test('asks before switching to a different relay', () async {
      final store = AppStore.memory();
      var connects = 0;
      final controller = RemoteController(
        store: store,
        connector: (_) async {
          connects++;
          return _PairingSocket(reply: _pairedReply);
        },
      );
      addTearDown(controller.dispose);

      const first = 'wss://relay.example.com/ws';
      await controller.pairWithQr(payloadFor(first));
      expect(controller.pairing?.relayUrl, first);
      final afterFirst = connects;

      final pending = await controller.pairWithQr(payloadFor('wss://new.example.com/ws'));

      expect(pending.status, QrPairStatus.needsRelayConfirm);
      expect(pending.needsRelayConfirm, isTrue);
      expect(pending.relayUrl, 'wss://new.example.com/ws');
      expect(pending.relayHost, 'new.example.com');
      expect(pending.previousRelayUrl, first);
      expect(pending.previousRelayHost, 'relay.example.com');
      // Nothing was dialled and the saved pairing is untouched.
      expect(connects, afterFirst);
      expect(controller.pairing?.relayUrl, first);
    });

    test('applies the new relay once confirmed', () async {
      final store = AppStore.memory();
      final controller = RemoteController(
        store: store,
        connector: (_) async => _PairingSocket(reply: _pairedReply),
      );
      addTearDown(controller.dispose);

      await controller.pairWithQr(payloadFor('wss://relay.example.com/ws'));
      const next = 'wss://new.example.com/ws';
      final payload = payloadFor(next);

      expect((await controller.pairWithQr(payload)).needsRelayConfirm, isTrue);
      final applied = await controller.pairWithQr(payload, confirmed: true);

      expect(applied.status, QrPairStatus.paired);
      expect(controller.pairing?.relayUrl, next);
      expect(store.lastRelayUrl, next);
    });

    test('does not ask when there is no previous relay', () async {
      final store = AppStore.memory();
      final controller = RemoteController(
        store: store,
        connector: (_) async => _PairingSocket(reply: _pairedReply),
      );
      addTearDown(controller.dispose);

      final result = await controller.pairWithQr(payloadFor(_relay));
      expect(result.needsRelayConfirm, isFalse);
      expect(result.previousRelayUrl, isNull);
      expect(result.previousRelayHost, isNull);
    });

    test('falls back to the last used relay when unpaired', () async {
      final store = AppStore.memory();
      await store.setString('lastRelayUrl', 'wss://old.example.com/ws');
      var connects = 0;
      final controller = RemoteController(
        store: store,
        connector: (_) async {
          connects++;
          return _PairingSocket(reply: _pairedReply);
        },
      );
      addTearDown(controller.dispose);

      final result = await controller.pairWithQr(payloadFor(_relay));

      expect(result.needsRelayConfirm, isTrue);
      expect(result.previousRelayHost, 'old.example.com');
      expect(connects, 0);
      expect(controller.pairing, isNull);
    });

    test('does not ask again when the relay matches the saved pairing', () async {
      final store = AppStore.memory();
      final controller = RemoteController(
        store: store,
        connector: (_) async => _PairingSocket(reply: _pairedReply),
      );
      addTearDown(controller.dispose);

      await controller.pairWithQr(payloadFor(_relay));
      final again = await controller.pairWithQr(payloadFor(_relay));

      expect(again.needsRelayConfirm, isFalse);
      expect(again.previousRelayUrl, _relay);
      expect(controller.pairing?.relayUrl, _relay);
    });

    test('reports a Chinese error for an unparsable payload', () async {
      final store = AppStore.memory();
      final controller = RemoteController(
        store: store,
        connector: (_) async => _PairingSocket(reply: _pairedReply),
      );
      addTearDown(controller.dispose);

      for (final bad in <String>[
        'nope',
        'https://relay.example.com',
        'cloudterminal://pair?code=ABCD2345',
        'cloudterminal://pair?relay=wss%3A%2F%2Fr%2Fws&code=SHORT',
      ]) {
        await expectLater(
          controller.pairWithQr(bad),
          throwsA(
            isA<RemoteException>().having(
              (e) => e.message,
              'message',
              contains('无法识别配对二维码'),
            ),
          ),
        );
      }
      expect(controller.pairing, isNull);
    });
  });
}
