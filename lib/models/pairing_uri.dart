import '../net/relay_socket.dart';

/// A parsed CloudTerminal pairing link.
///
/// Wire format (what the desktop agent renders as a QR code, and what the
/// phone can paste in when a camera scanner is unavailable):
///
/// ```text
/// cloudterminal://pair?relay=<urlencoded ws(s) url>&code=XXXXXXXX&v=1
/// ```
///
/// [relay] is already normalized by [normalizeRelayUrl], so it always has a
/// `ws` / `wss` scheme and a path.
class PairingUri {
  const PairingUri({
    required this.relay,
    required this.code,
    this.version = currentVersion,
  });

  /// Protocol version this build understands.
  static const int currentVersion = 1;

  /// URI scheme shown on the desktop.
  static const String scheme = 'cloudterminal';

  /// URI host shown on the desktop.
  static const String host = 'pair';

  /// Normalized `ws` / `wss` relay endpoint.
  final Uri relay;

  /// Eight uppercase alphanumeric characters, without the cosmetic dash.
  final String code;

  /// Value of the `v` parameter; absent in the payload means [currentVersion].
  final int version;

  /// Parses a scanned / pasted payload. Returns `null` when [payload] is not
  /// a CloudTerminal pairing link (the caller turns that into a message).
  ///
  /// Lenient on purpose: surrounding text and whitespace are tolerated, so a
  /// QR scanner that returns the link prefixed with its own label (for
  /// example `content: ...`) still works.
  static PairingUri? tryParse(String? payload) {
    if (payload == null) return null;
    final text = payload.trim();
    if (text.isEmpty) return null;

    final marker = '$scheme://$host';
    final start = text.indexOf(marker);
    if (start < 0) return null;
    // Cut trailing prose / newlines the scanner may have appended.
    var raw = text.substring(start);
    final end = raw.indexOf(RegExp(r'\s'));
    if (end >= 0) raw = raw.substring(0, end);

    final Uri uri;
    try {
      uri = Uri.parse(raw);
    } on FormatException {
      return null;
    }
    if (uri.scheme != scheme || uri.host != host) return null;

    final params = uri.queryParameters;
    final relayInput = params['relay'];
    if (relayInput == null || relayInput.isEmpty) return null;

    // `queryParameters` already percent-decodes the value.
    final relay = normalizeRelayUrl(relayInput);
    if (relay == null) return null;

    final code = normalizePairCode(params['code']);
    if (code == null) return null;

    final version = _parseVersion(params['v']);
    if (version == null) return null;

    return PairingUri(relay: relay, code: code, version: version);
  }

  /// Renders the canonical payload (used by tests and by the desktop mirror).
  String encode() {
    final query = <String, String>{
      'relay': relay.toString(),
      'code': code,
      'v': '$version',
    }.entries
        .map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
    return '$scheme://$host?$query';
  }

  /// Uppercase [code] and drop the formatting dash; `null` unless exactly
  /// eight alphanumeric characters remain.
  static String? normalizePairCode(String? code) {
    if (code == null) return null;
    final cleaned = code.toUpperCase().replaceAll(RegExp(r'[^0-9A-Z]'), '');
    return cleaned.length == 8 ? cleaned : null;
  }

  static int? _parseVersion(String? raw) {
    if (raw == null || raw.isEmpty) return currentVersion;
    final value = int.tryParse(raw);
    if (value == null || value < 1) return null;
    return value;
  }

  @override
  String toString() => encode();
}
