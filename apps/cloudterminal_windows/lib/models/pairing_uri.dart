/// The `cloudterminal://pair?...` payload shown as a QR code on this PC and
/// scanned (or pasted) on the phone.
///
/// This is the machine-readable form of the pairing banner that already exists:
/// it carries the relay address plus the one-time code, and **never** a
/// long-lived secret. The phone still exchanges the code for credentials
/// through the relay.
///
/// Mirrors `server/src/shared/pairing.ts`; both sides are covered by tests.
library;

class PairUri {
  const PairUri({required this.relayUrl, required this.code, this.version = 1});

  final String relayUrl;
  final String code;
  final int version;

  static const String scheme = 'cloudterminal';
  static const String host = 'pair';

  /// Encode. Field order is stable so tests can assert the exact string.
  String encode() {
    final params = <String, String>{
      'relay': relayUrl,
      'code': code,
      'v': '$version',
    };
    final query = params.entries
        .map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
    return '$scheme://$host?$query';
  }

  @override
  String toString() => encode();

  /// Parse a scanned/pasted payload. Returns null when it is not a valid
  /// CloudTerminal pairing URI; callers show an actionable message.
  static PairUri? tryParse(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;
    final uri = Uri.tryParse(trimmed);
    if (uri == null) return null;
    if (uri.scheme != scheme || uri.host != host) return null;
    final relay = uri.queryParameters['relay'];
    final code = uri.queryParameters['code'];
    if (relay == null || relay.isEmpty || code == null || code.isEmpty) {
      return null;
    }
    if (!_isRelayUrl(relay)) return null;
    final version = int.tryParse(uri.queryParameters['v'] ?? '1') ?? 1;
    return PairUri(relayUrl: relay, code: _normalizeCode(code), version: version);
  }

  /// Accepts a raw 8-char code too, matching the desktop agent's alphabet.
  static String _normalizeCode(String code) {
    final cleaned = code.toUpperCase().replaceAll(RegExp('[^0-9A-Z]'), '');
    return cleaned;
  }

  static bool _isRelayUrl(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null) return false;
    if (uri.scheme != 'ws' && uri.scheme != 'wss') return false;
    return uri.host.isNotEmpty;
  }

  /// Format an 8-char code as `XXXX-XXXX` for display.
  static String displayCode(String code) {
    final cleaned = _normalizeCode(code);
    if (cleaned.length != 8) return cleaned;
    return '${cleaned.substring(0, 4)}-${cleaned.substring(4)}';
  }
}
