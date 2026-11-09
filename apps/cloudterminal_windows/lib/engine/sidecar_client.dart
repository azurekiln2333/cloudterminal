import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Client for the Node sidecar's local, loopback-only JSON-line IPC.
///
/// The sidecar prints `{"port":N}` as its first stdout line, then serves a
/// line-delimited JSON protocol on `127.0.0.1:N`. Everything the UI shows about
/// the relay, pairing and tools flows through here; the Flutter app never talks
/// to the relay directly, so the existing Node handshake, reconnect and protocol
/// mirroring stay in one place.
class SidecarClient {
  SidecarClient({
    required this.executable,
    required this.arguments,
    this.workingDirectory,
    this.environment,
  });

  final String executable;
  final List<String> arguments;
  final String? workingDirectory;

  /// Extra environment for the sidecar process (e.g. an isolated config home
  /// during tests). Merged over the current environment when set.
  final Map<String, String>? environment;

  Process? _process;
  Socket? _socket;
  StreamSubscription<String>? _lines;
  final StreamController<Map<String, dynamic>> _messages =
      StreamController<Map<String, dynamic>>.broadcast();
  final Completer<void> _ready = Completer<void>();
  String _buffer = '';
  bool _stopped = false;

  /// Frames pushed by the sidecar (`snapshot`, `pair_code`, `stream_event`, ...).
  Stream<Map<String, dynamic>> get messages => _messages.stream;

  /// Completes once the sidecar is listening and the socket is connected.
  Future<void> get ready => _ready.future;

  int? get port => _port;
  int? _port;

  Future<void> start() async {
    _stopped = false;
    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      includeParentEnvironment: true,
      runInShell: false,
    );
    _process = process;
    process.stderr
        .transform(utf8.decoder)
        .listen((chunk) => _messages.add(<String, dynamic>{
              'type': '_stderr',
              'text': chunk,
            }));

    final portCompleter = Completer<int>();
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      if (!portCompleter.isCompleted) {
        final decoded = _tryDecode(line);
        final port = decoded?['port'];
        if (decoded?['type'] == 'listening' && port is num) {
          portCompleter.complete(port.toInt());
          return;
        }
      }
    });

    final port = await portCompleter.future.timeout(
      const Duration(seconds: 20),
      onTimeout: () => throw StateError('后台服务未在 20 秒内就绪'),
    );
    _port = port;
    await _connect(port);
    if (!_ready.isCompleted) _ready.complete();
  }

  Future<void> _connect(int port) async {
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      port,
      timeout: const Duration(seconds: 5),
    );
    _socket = socket;
    _lines = socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          _onLine,
          onError: (Object e) => _messages.add(<String, dynamic>{
            'type': '_error',
            'text': '$e',
          }),
        );
  }

  void _onLine(String line) {
    if (_buffer.isNotEmpty) {
      line = '$_buffer$line';
      _buffer = '';
    }
    final decoded = _tryDecode(line);
    if (decoded == null) {
      // Partial line: keep it for the next chunk.
      _buffer = line;
      return;
    }
    _messages.add(decoded);
  }

  Map<String, dynamic>? _tryDecode(String line) {
    final text = line.trim();
    if (text.isEmpty || !text.startsWith('{')) return null;
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return decoded.cast<String, dynamic>();
    } on FormatException {
      return null;
    }
    return null;
  }

  /// Send one request frame.
  void send(String type, [Map<String, dynamic> fields = const {}]) {
    final socket = _socket;
    if (socket == null) return;
    socket.write('${jsonEncode(<String, dynamic>{'type': type, ...fields})}\n');
  }

  /// Request a fresh one-time pairing code and QR payload.
  void requestPairCode() => send('pair_code');

  /// Regenerate the agent identity (invalidates phones' stored credentials).
  void resetPairing() => send('reset_pairing');

  /// Ask the sidecar to re-probe installed tools.
  void probeTools() => send('tool_probe');

  /// Set or clear the relay address (and optional registration key) and
  /// reconnect. Clearing the address switches to local-relay mode.
  void setRelay({String? url, String? key, bool clear = false}) => send(
    'set_relay',
    <String, dynamic>{'url': url, 'key': key, 'clear': clear},
  );

  /// Bind / unbind a session by id.
  void bindSession(String sessionId) =>
      send('tool_bind', <String, dynamic>{'id': sessionId});
  void unbindSession(String sessionId) =>
      send('tool_unbind', <String, dynamic>{'id': sessionId});

  /// Start a new managed Claude stream (真流).
  void startManagedClaude({String? prompt}) => send(
    'tool_start_managed',
    <String, dynamic>{'kind': 'claude', 'prompt': prompt},
  );

  /// Send input to a managed session.
  void sendInput(String sessionId, String text) =>
      send('tool_input', <String, dynamic>{'id': sessionId, 'text': text});

  /// Change a poll interval for a polling binding.
  void setPollInterval(String sessionId, int milliseconds) => send(
    'tool_poll_interval',
    <String, dynamic>{'id': sessionId, 'intervalMs': milliseconds},
  );

  Future<void> stop() async {
    _stopped = true;
    await _lines?.cancel();
    await _socket?.close();
    _socket = null;
    final process = _process;
    if (process != null) {
      process.kill();
      await process.exitCode.timeout(
        const Duration(seconds: 5),
        onTimeout: () => 0,
      );
    }
    _process = null;
  }

  bool get isStopped => _stopped;

  Future<void> dispose() async {
    await stop();
    await _messages.close();
  }
}
