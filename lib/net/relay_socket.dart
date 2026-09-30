import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Minimal socket surface the app needs, so tests can swap in a fake.
abstract class RelaySocket {
  /// Decoded JSON frames. Completes when the socket closes.
  Stream<Map<String, dynamic>> get frames;

  void send(Map<String, dynamic> frame);

  Future<void> close();

  int? get closeCode;
  String? get closeReason;
}

typedef RelayConnector = Future<RelaySocket> Function(Uri url);

/// dart:io WebSocket. Works on Android, iOS, desktop and OpenHarmony without
/// a plugin; the relay's 30 s pings keep NAT mappings alive and the
/// [pingInterval] here detects dead links from our side.
Future<RelaySocket> connectIoSocket(Uri url) async {
  final ws = await WebSocket.connect(url.toString())
      .timeout(const Duration(seconds: 15));
  ws.pingInterval = const Duration(seconds: 25);
  return _IoRelaySocket(ws);
}

class _IoRelaySocket implements RelaySocket {
  _IoRelaySocket(this._ws)
      : frames = _ws
            .where((data) => data is String)
            .map<Map<String, dynamic>?>((data) {
              try {
                final decoded = jsonDecode(data as String);
                return decoded is Map<String, dynamic> ? decoded : null;
              } on FormatException {
                return null;
              }
            })
            .where((frame) => frame != null)
            .cast<Map<String, dynamic>>()
            .asBroadcastStream();

  final WebSocket _ws;

  @override
  final Stream<Map<String, dynamic>> frames;

  @override
  void send(Map<String, dynamic> frame) {
    if (_ws.readyState == WebSocket.open) _ws.add(jsonEncode(frame));
  }

  @override
  Future<void> close() => _ws.close(1000);

  @override
  int? get closeCode => _ws.closeCode;

  @override
  String? get closeReason => _ws.closeReason;
}

/// Accepts what people actually type ("relay.example.com", "https://x/",
/// "192.168.1.5:8787") and produces a WebSocket URL ending in /ws.
///
/// Bare hosts default to wss:// except for LAN / loopback addresses, where a
/// TLS terminator is unlikely.
Uri? normalizeRelayUrl(String input) {
  var text = input.trim();
  if (text.isEmpty) return null;
  if (!text.contains('://')) {
    final host = text.split(RegExp(r'[:/]')).first;
    text = '${_isLocalHost(host) ? 'ws' : 'wss'}://$text';
  }
  final Uri uri;
  try {
    uri = Uri.parse(text);
  } on FormatException {
    return null;
  }
  final scheme = switch (uri.scheme) {
    'http' || 'ws' => 'ws',
    'https' || 'wss' => 'wss',
    _ => null,
  };
  if (scheme == null || uri.host.isEmpty) return null;
  final path = uri.path.isEmpty || uri.path == '/' ? '/ws' : uri.path;
  return Uri(
    scheme: scheme,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
    path: path,
  );
}

bool _isLocalHost(String host) {
  if (host == 'localhost' || host.endsWith('.local')) return true;
  final parts = host.split('.').map(int.tryParse).toList();
  if (parts.length != 4 || parts.any((p) => p == null)) return false;
  final a = parts[0]!;
  final b = parts[1]!;
  return a == 127 ||
      a == 10 ||
      (a == 192 && b == 168) ||
      (a == 172 && b >= 16 && b <= 31);
}
