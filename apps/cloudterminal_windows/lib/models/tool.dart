import 'dart:convert';

/// Tools this assistant can discover and bind.
enum ToolKind {
  herdr('herdr', 'Herdr', '多路复用终端与 agent 宿主'),
  codex('codex', 'Codex', 'OpenAI Codex CLI'),
  claude('claude', 'Claude Code', 'Anthropic Claude Code (cc)');

  const ToolKind(this.wire, this.label, this.description);

  final String wire;
  final String label;
  final String description;

  static ToolKind? fromWire(Object? value) {
    for (final kind in ToolKind.values) {
      if (kind.wire == value) return kind;
    }
    return null;
  }
}

/// How a binding gets its output. This drives whether the UI may call it
/// "live". A poll or a history snapshot must never be labelled as a stream.
enum StreamOrigin {
  /// A real event stream from a process/daemon we manage (Codex app-server
  /// notifications, Claude `--output-format stream-json`).
  managedStream('managed-stream', '实时流'),

  /// A one-shot or re-read history listing (Codex ThreadRead, `claude logs`).
  daemonHistory('daemon-history', '只读历史'),

  /// Repeated reads of a screen buffer because the tool exposes no change feed
  /// (Herdr `pane read`).
  panePoll('pane-poll', '轮询');

  const StreamOrigin(this.wire, this.label);

  final String wire;
  final String label;

  bool get isLive => this == StreamOrigin.managedStream;

  static StreamOrigin fromWire(Object? value) => StreamOrigin.values.firstWhere(
    (o) => o.wire == value,
    orElse: () => StreamOrigin.daemonHistory,
  );
}

/// Discovery result for one tool on this machine.
class ToolProbe {
  const ToolProbe({
    required this.kind,
    required this.installed,
    this.version,
    this.executable,
    this.daemonRunning = false,
    this.loggedIn,
    this.reason,
  });

  factory ToolProbe.fromJson(Map<String, dynamic> json) => ToolProbe(
    kind: ToolKind.fromWire(json['kind']) ?? ToolKind.herdr,
    installed: json['installed'] == true,
    version: _str(json['version']),
    executable: _str(json['executable']),
    daemonRunning: json['daemonRunning'] == true,
    loggedIn: json['loggedIn'] is bool ? json['loggedIn'] as bool : null,
    reason: _str(json['reason']),
  );

  final ToolKind kind;
  final bool installed;
  final String? version;
  final String? executable;
  final bool daemonRunning;
  final bool? loggedIn;
  final String? reason;

  /// Whether this tool can be bound at all right now.
  bool get bindable => installed;

  String get statusLabel {
    if (!installed) return '未安装';
    if (loggedIn == false) return '未登录';
    final v = version ?? '';
    return v.isEmpty ? '已安装' : '已安装 $v';
  }
}

/// One selectable session/thread/pane inside a bound tool.
class SessionBinding {
  const SessionBinding({
    required this.kind,
    required this.id,
    required this.title,
    required this.origin,
    this.subtitle,
    this.pollInterval,
    this.canAcceptInput = false,
    this.cwd,
    this.status,
  });

  factory SessionBinding.fromJson(Map<String, dynamic> json) => SessionBinding(
    kind: ToolKind.fromWire(json['kind']) ?? ToolKind.herdr,
    id: _str(json['id']) ?? '',
    title: _str(json['title']) ?? '',
    subtitle: _str(json['subtitle']),
    origin: StreamOrigin.fromWire(json['origin']),
    pollInterval: json['pollIntervalMs'] is num
        ? Duration(milliseconds: (json['pollIntervalMs'] as num).toInt())
        : null,
    canAcceptInput: json['canAcceptInput'] == true,
    cwd: _str(json['cwd']),
    status: _str(json['status']),
  );

  final ToolKind kind;
  final String id;
  final String title;
  final String? subtitle;
  final StreamOrigin origin;
  final Duration? pollInterval;
  final bool canAcceptInput;
  final String? cwd;
  final String? status;

  /// Honest label shown on every binding: never call a poll "live".
  String get originLabel {
    if (origin == StreamOrigin.panePoll && pollInterval != null) {
      return '轮询 ${(pollInterval!.inMilliseconds / 1000).toStringAsFixed(1)}s';
    }
    return origin.label;
  }
}

/// A line of tool output delivered to the UI.
class ToolEvent {
  const ToolEvent({
    required this.kind,
    required this.sessionId,
    required this.kindLabel,
    required this.text,
    this.seq = 0,
    this.done = false,
  });

  factory ToolEvent.fromJson(Map<String, dynamic> json) => ToolEvent(
    kind: ToolKind.fromWire(json['kind']) ?? ToolKind.herdr,
    sessionId: _str(json['sessionId']) ?? '',
    kindLabel: _str(json['eventKind']) ?? 'output',
    text: _str(json['text']) ?? '',
    seq: json['seq'] is num ? (json['seq'] as num).toInt() : 0,
    done: json['done'] == true,
  );

  final ToolKind kind;
  final String sessionId;
  final String kindLabel;
  final String text;
  final int seq;
  final bool done;

  /// True when this event replaces the whole buffer (history / poll snapshot).
  bool get isSnapshot => kindLabel == 'snapshot';
}

/// Overall assistant state pushed by the sidecar.
class AssistantSnapshot {
  const AssistantSnapshot({
    required this.relayOnline,
    this.relayUrl,
    this.retries = 0,
    this.lastError,
    this.pairedClients = 0,
    this.tools = const <ToolProbe>[],
    this.bindings = const <SessionBinding>[],
    this.statusPort,
  });

  factory AssistantSnapshot.fromJson(Map<String, dynamic> json) =>
      AssistantSnapshot(
        relayOnline: json['relayOnline'] == true,
        relayUrl: _str(json['relayUrl']),
        retries: json['retries'] is num ? (json['retries'] as num).toInt() : 0,
        lastError: _str(json['lastError']),
        pairedClients: json['pairedClients'] is num
            ? (json['pairedClients'] as num).toInt()
            : 0,
        tools: <ToolProbe>[
          for (final raw in (json['tools'] as List<dynamic>? ?? <dynamic>[]))
            if (raw is Map<String, dynamic>) ToolProbe.fromJson(raw)
            else if (raw is Map) ToolProbe.fromJson(raw.cast<String, dynamic>()),
        ],
        bindings: <SessionBinding>[
          for (final raw in (json['bindings'] as List<dynamic>? ?? <dynamic>[]))
            if (raw is Map<String, dynamic>)
              SessionBinding.fromJson(raw)
            else if (raw is Map)
              SessionBinding.fromJson(raw.cast<String, dynamic>()),
        ],
        statusPort: json['statusPort'] is num
            ? (json['statusPort'] as num).toInt()
            : null,
      );

  final bool relayOnline;
  final String? relayUrl;
  final int retries;
  final String? lastError;
  final int pairedClients;
  final List<ToolProbe> tools;
  final List<SessionBinding> bindings;
  final int? statusPort;

  ToolProbe? probe(ToolKind kind) {
    for (final t in tools) {
      if (t.kind == kind) return t;
    }
    return null;
  }
}

/// One-time pairing code plus the QR payload that encodes it.
class PairCodeInfo {
  const PairCodeInfo({
    required this.display,
    required this.uri,
    required this.expiresAt,
  });

  factory PairCodeInfo.fromJson(Map<String, dynamic> json) => PairCodeInfo(
    display: _str(json['display']) ?? '',
    uri: _str(json['uri']) ?? '',
    expiresAt: json['expiresAt'] is num
        ? DateTime.fromMillisecondsSinceEpoch(
            (json['expiresAt'] as num).toInt(),
          )
        : DateTime.now(),
  );

  final String display;
  final String uri;
  final DateTime expiresAt;

  Duration get remaining => expiresAt.difference(DateTime.now());
}

String? _str(Object? value) => value is String && value.isNotEmpty ? value : null;

/// Lenient JSON object decode used by the IPC layer.
Map<String, dynamic>? decodeJsonObject(String text) {
  try {
    final decoded = jsonDecode(text);
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) return decoded.cast<String, dynamic>();
  } on FormatException {
    return null;
  }
  return null;
}
