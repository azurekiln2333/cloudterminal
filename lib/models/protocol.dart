// Dart mirror of server/src/shared/protocol.ts. Parsing is lenient: unknown
// fields are ignored and unknown event kinds become [UnknownEvent], so an
// older app keeps working against a newer agent.

typedef Json = Map<String, dynamic>;

String _str(Object? v) => v is String ? v : '';
int _int(Object? v) => v is num ? v.toInt() : 0;
double _double(Object? v) => v is num ? v.toDouble() : 0;
DateTime _time(Object? v) =>
    DateTime.fromMillisecondsSinceEpoch(_int(v), isUtc: false);

/// Lifecycle of a session on the PC.
enum SessionStatus { starting, running, waiting, idle, error, closed }

SessionStatus parseSessionStatus(Object? value) {
  for (final status in SessionStatus.values) {
    if (status.name == value) return status;
  }
  return SessionStatus.idle;
}

/// Wire names of Claude Code permission modes, in menu order.
class PermissionModes {
  const PermissionModes._();

  static const String defaultMode = 'default';
  static const String bypass = 'bypassPermissions';

  static const List<String> all = <String>[
    'default',
    'acceptEdits',
    'plan',
    'auto',
    'dontAsk',
    'bypassPermissions',
  ];

  static String label(String mode) {
    switch (mode) {
      case 'default':
        return '默认';
      case 'acceptEdits':
        return '自动接受编辑';
      case 'plan':
        return '计划模式';
      case 'auto':
        return '自动判断';
      case 'dontAsk':
        return '不询问';
      case 'bypassPermissions':
        return '跳过权限';
      default:
        return mode;
    }
  }

  static String description(String mode) {
    switch (mode) {
      case 'default':
        return '每次需要权限都会在手机上询问你';
      case 'acceptEdits':
        return '文件编辑自动通过，命令等仍需授权';
      case 'plan':
        return '只读分析并给出计划，执行前征求同意';
      case 'auto':
        return '由分类器判断，拿不准时再问你';
      case 'dontAsk':
        return '未预先允许的操作一律拒绝，不打扰你';
      case 'bypassPermissions':
        return '不做任何权限检查，风险最高';
      default:
        return '';
    }
  }
}

class SessionInfo {
  const SessionInfo({
    required this.id,
    required this.title,
    required this.cwd,
    required this.status,
    required this.mode,
    required this.createdAt,
    required this.updatedAt,
    this.model,
    this.claudeSessionId,
    this.costUsd = 0,
    this.pending = 0,
    this.lastSeq = 0,
    this.kind = 'claude',
    this.cols,
    this.rows,
  });

  factory SessionInfo.fromJson(Json json) => SessionInfo(
    id: _str(json['id']),
    title: _str(json['title']),
    cwd: _str(json['cwd']),
    status: parseSessionStatus(json['status']),
    mode: _str(json['mode']).isEmpty ? 'default' : _str(json['mode']),
    model: json['model'] as String?,
    claudeSessionId: json['claudeSessionId'] as String?,
    createdAt: _time(json['createdAt']),
    updatedAt: _time(json['updatedAt']),
    costUsd: _double(json['costUsd']),
    pending: _int(json['pending']),
    lastSeq: _int(json['lastSeq']),
    kind: json['kind'] == 'terminal' ? 'terminal' : 'claude',
    cols: json['cols'] is num ? _int(json['cols']) : null,
    rows: json['rows'] is num ? _int(json['rows']) : null,
  );

  final String id;
  final String title;
  final String cwd;
  final SessionStatus status;
  final String mode;
  final String? model;
  final String? claudeSessionId;
  final DateTime createdAt;
  final DateTime updatedAt;
  final double costUsd;
  final int pending;
  final int lastSeq;
  final String kind;
  final int? cols;
  final int? rows;
  bool get isTerminal => kind == 'terminal';

  bool get isBusy =>
      status == SessionStatus.running || status == SessionStatus.waiting;
  bool get isClosed => status == SessionStatus.closed;
}

class AgentInfo {
  const AgentInfo({
    required this.host,
    required this.platform,
    required this.defaultCwd,
    required this.roots,
    required this.allowBypass,
    this.capabilities = const <String>[],
    this.codex,
  });

  factory AgentInfo.fromJson(Json json) => AgentInfo(
    host: _str(json['host']),
    platform: _str(json['platform']),
    defaultCwd: _str(json['defaultCwd']),
    roots: <String>[
      for (final r in (json['roots'] as List<dynamic>? ?? <dynamic>[]))
        if (r is String) r,
    ],
    allowBypass: json['allowBypass'] == true,
    codex: json['codex'] is Json
        ? CodexAvailability.fromJson(json['codex'] as Json)
        : null,
    capabilities: <String>[
      for (final value
          in (json['capabilities'] as List<dynamic>? ?? <dynamic>[]))
        if (value is String) value,
    ],
  );

  final String host;
  final String platform;
  final String defaultCwd;
  final List<String> roots;
  final bool allowBypass;
  final List<String> capabilities;
  final CodexAvailability? codex;
}

class HistoryItem {
  const HistoryItem({
    required this.sessionId,
    required this.summary,
    required this.lastModified,
    this.cwd,
  });

  factory HistoryItem.fromJson(Json json) => HistoryItem(
    sessionId: _str(json['sessionId']),
    summary: _str(json['summary']),
    cwd: json['cwd'] as String?,
    lastModified: _time(json['lastModified']),
  );

  final String sessionId;
  final String summary;
  final String? cwd;
  final DateTime lastModified;
}

class DirEntry {
  const DirEntry(this.name, this.path);

  final String name;
  final String path;
}

class DirListing {
  const DirListing({
    required this.path,
    required this.parent,
    required this.entries,
  });

  factory DirListing.fromJson(Json json) => DirListing(
    path: _str(json['path']),
    parent: json['parent'] as String?,
    entries: <DirEntry>[
      for (final e in (json['entries'] as List<dynamic>? ?? <dynamic>[]))
        if (e is Map) DirEntry(_str(e['name']), _str(e['path'])),
    ],
  );

  /// '' is the virtual list of allowed roots.
  final String path;

  /// null at the top; '' means "back to the root list".
  final String? parent;
  final List<DirEntry> entries;

  bool get isRootList => path.isEmpty;
}

class QuestionOption {
  const QuestionOption(this.label, [this.description]);

  final String label;
  final String? description;
}

class Question {
  const Question({
    required this.question,
    required this.options,
    this.header,
    this.multiSelect = false,
  });

  factory Question.fromJson(Json json) => Question(
    question: _str(json['question']),
    header: json['header'] as String?,
    multiSelect: json['multiSelect'] == true,
    options: <QuestionOption>[
      for (final o in (json['options'] as List<dynamic>? ?? <dynamic>[]))
        if (o is Map)
          QuestionOption(_str(o['label']), o['description'] as String?),
    ],
  );

  final String question;
  final String? header;
  final bool multiSelect;
  final List<QuestionOption> options;
}

// ---------------------------------------------------------------------------
// Session events
// ---------------------------------------------------------------------------

sealed class SessionEvent {
  const SessionEvent(this.seq, this.ts);

  factory SessionEvent.fromJson(Json json) {
    final seq = _int(json['seq']);
    final ts = _time(json['ts']);
    switch (json['kind']) {
      case 'terminal_output':
        return TerminalOutputEvent(seq, ts, _str(json['data']));
      case 'user':
        return UserEvent(seq, ts, _str(json['text']));
      case 'assistant':
        return AssistantEvent(seq, ts, _str(json['text']));
      case 'thinking':
        return ThinkingEvent(seq, ts, _str(json['text']));
      case 'tool_use':
        return ToolUseEvent(
          seq,
          ts,
          toolUseId: _str(json['toolUseId']),
          name: _str(json['name']),
          summary: _str(json['summary']),
          input: json['input'],
        );
      case 'tool_result':
        return ToolResultEvent(
          seq,
          ts,
          toolUseId: _str(json['toolUseId']),
          content: _str(json['content']),
          isError: json['isError'] == true,
        );
      case 'permission_request':
        final questions = json['questions'];
        return PermissionRequestEvent(
          seq,
          ts,
          requestId: _str(json['requestId']),
          toolName: _str(json['toolName']),
          title: _str(json['title']),
          description: json['description'] as String?,
          input: json['input'],
          canAlwaysAllow: json['canAlwaysAllow'] == true,
          questions: questions is List
              ? <Question>[
                  for (final q in questions)
                    if (q is Map<String, dynamic>) Question.fromJson(q),
                ]
              : null,
        );
      case 'permission_resolved':
        return PermissionResolvedEvent(
          seq,
          ts,
          requestId: _str(json['requestId']),
          decision: _str(json['decision']),
        );
      case 'result':
        return ResultEvent(
          seq,
          ts,
          subtype: _str(json['subtype']),
          isError: json['isError'] == true,
          text: _str(json['text']),
          costUsd: _double(json['costUsd']),
          duration: Duration(milliseconds: _int(json['durationMs'])),
          turns: _int(json['turns']),
        );
      case 'system':
        return SystemEvent(seq, ts, _str(json['text']));
      case 'error':
        return ErrorEvent(seq, ts, _str(json['text']));
      default:
        return UnknownEvent(seq, ts, _str(json['kind']));
    }
  }

  final int seq;
  final DateTime ts;
}

final class UserEvent extends SessionEvent {
  const UserEvent(super.seq, super.ts, this.text);
  final String text;
}

final class AssistantEvent extends SessionEvent {
  const AssistantEvent(super.seq, super.ts, this.text);
  final String text;
}

final class ThinkingEvent extends SessionEvent {
  const ThinkingEvent(super.seq, super.ts, this.text);
  final String text;
}

final class ToolUseEvent extends SessionEvent {
  const ToolUseEvent(
    super.seq,
    super.ts, {
    required this.toolUseId,
    required this.name,
    required this.summary,
    required this.input,
  });

  final String toolUseId;
  final String name;
  final String summary;
  final Object? input;
}

final class ToolResultEvent extends SessionEvent {
  const ToolResultEvent(
    super.seq,
    super.ts, {
    required this.toolUseId,
    required this.content,
    required this.isError,
  });

  final String toolUseId;
  final String content;
  final bool isError;
}

final class PermissionRequestEvent extends SessionEvent {
  const PermissionRequestEvent(
    super.seq,
    super.ts, {
    required this.requestId,
    required this.toolName,
    required this.title,
    required this.input,
    required this.canAlwaysAllow,
    this.description,
    this.questions,
  });

  final String requestId;
  final String toolName;
  final String title;
  final String? description;
  final Object? input;
  final bool canAlwaysAllow;

  /// Set for AskUserQuestion: answer instead of allow/deny.
  final List<Question>? questions;

  bool get isQuestion => questions != null && questions!.isNotEmpty;
}

final class PermissionResolvedEvent extends SessionEvent {
  const PermissionResolvedEvent(
    super.seq,
    super.ts, {
    required this.requestId,
    required this.decision,
  });

  final String requestId;

  /// allow | allow_always | deny
  final String decision;
}

final class ResultEvent extends SessionEvent {
  const ResultEvent(
    super.seq,
    super.ts, {
    required this.subtype,
    required this.isError,
    required this.text,
    required this.costUsd,
    required this.duration,
    required this.turns,
  });

  final String subtype;
  final bool isError;
  final String text;
  final double costUsd;
  final Duration duration;
  final int turns;
}

final class SystemEvent extends SessionEvent {
  const SystemEvent(super.seq, super.ts, this.text);
  final String text;
}

final class ErrorEvent extends SessionEvent {
  const ErrorEvent(super.seq, super.ts, this.text);
  final String text;
}

final class UnknownEvent extends SessionEvent {
  const UnknownEvent(super.seq, super.ts, this.kind);
  final String kind;
}

final class TerminalOutputEvent extends SessionEvent {
  const TerminalOutputEvent(super.seq, super.ts, this.data);
  final String data;
}

/// Desktop catalog is independent from agent-managed terminal/Claude sessions.
class CodexAvailability {
  const CodexAvailability({
    required this.available,
    required this.canControl,
    this.reason,
  });
  factory CodexAvailability.fromJson(Json json) => CodexAvailability(
    available: json['available'] == true,
    canControl: json['canControl'] == true,
    reason: json['reason'] is String ? json['reason'] as String : null,
  );
  final bool available;
  final bool canControl;
  final String? reason;
}

class CodexProject {
  const CodexProject({
    required this.id,
    required this.title,
    required this.roots,
  });
  factory CodexProject.fromJson(Json json) => CodexProject(
    id: _str(json['id']),
    title: _str(json['title']),
    roots: <String>[
      for (final root
          in (json['roots'] is List ? json['roots'] as List : <dynamic>[]))
        if (root is String) root,
    ],
  );
  final String id;
  final String title;
  final List<String> roots;
}

class CodexThread {
  const CodexThread({
    required this.id,
    required this.title,
    required this.cwd,
    required this.updatedAt,
    required this.status,
    required this.canAcceptDirectInput,
    required this.canResume,
    this.projectId,
    this.activeTurnId,
  });
  factory CodexThread.fromJson(Json json) => CodexThread(
    id: _str(json['id']),
    title: _str(json['title']),
    cwd: _str(json['cwd']),
    projectId: json['projectId'] is String ? json['projectId'] as String : null,
    updatedAt: _time(json['updatedAt']),
    status: _str(json['status']),
    canAcceptDirectInput: json['canAcceptDirectInput'] == true,
    canResume: json['canResume'] == true,
    activeTurnId: json['activeTurnId'] is String
        ? json['activeTurnId'] as String
        : null,
  );
  final String id;
  final String? projectId;
  final String title;
  final String cwd;
  final DateTime updatedAt;
  final String status;
  final bool canAcceptDirectInput;
  final bool canResume;
  final String? activeTurnId;
}

class CodexItem {
  const CodexItem({
    required this.id,
    required this.kind,
    required this.text,
    this.toolName,
  });
  factory CodexItem.fromJson(Json json) => CodexItem(
    id: _str(json['id']),
    kind: _str(json['kind']),
    text: _str(json['text']),
    toolName: json['toolName'] is String ? json['toolName'] as String : null,
  );
  final String id;
  final String kind;
  final String text;
  final String? toolName;
}

class CodexTurn {
  const CodexTurn({
    required this.id,
    required this.status,
    required this.items,
  });
  factory CodexTurn.fromJson(Json json) => CodexTurn(
    id: _str(json['id']),
    status: _str(json['status']),
    items: <CodexItem>[
      for (final item
          in (json['items'] is List ? json['items'] as List : <dynamic>[]))
        if (item is Json) CodexItem.fromJson(item),
    ],
  );
  final String id;
  final String status;
  final List<CodexItem> items;
}

class CodexPage<T> {
  const CodexPage(this.items, this.nextCursor);
  final List<T> items;
  final String? nextCursor;
}

class CodexTranscript {
  const CodexTranscript({
    required this.thread,
    required this.turns,
    this.nextCursor,
    this.pendingRequests = const <CodexPendingRequest>[],
  });
  factory CodexTranscript.fromJson(Json json) => CodexTranscript(
    thread: CodexThread.fromJson(json['thread'] as Json),
    turns: <CodexTurn>[
      for (final turn
          in (json['turns'] is List ? json['turns'] as List : <dynamic>[]))
        if (turn is Json) CodexTurn.fromJson(turn),
    ],
    nextCursor: json['nextCursor'] is String
        ? json['nextCursor'] as String
        : null,
    pendingRequests: <CodexPendingRequest>[
      for (final request
          in (json['pendingRequests'] is List
              ? json['pendingRequests'] as List
              : <dynamic>[]))
        if (request is Json) CodexPendingRequest.fromJson(request),
    ],
  );
  final CodexThread thread;
  final List<CodexTurn> turns;
  final String? nextCursor;
  final List<CodexPendingRequest> pendingRequests;
}

class CodexPendingRequest {
  const CodexPendingRequest({
    required this.requestId,
    required this.kind,
    required this.title,
    required this.canAccept,
    this.description,
    this.questions = const <CodexQuestion>[],
  });
  factory CodexPendingRequest.fromJson(Json json) => CodexPendingRequest(
    requestId: _str(json['requestId']),
    kind: _str(json['kind']),
    title: _str(json['title']),
    canAccept: json['canAccept'] == true,
    description: json['description'] is String
        ? json['description'] as String
        : null,
    questions: <CodexQuestion>[
      for (final question
          in (json['questions'] is List
              ? json['questions'] as List
              : <dynamic>[]))
        if (question is Json) CodexQuestion.fromJson(question),
    ],
  );
  final String requestId;
  final String kind;
  final String title;
  final String? description;
  final bool canAccept;
  final List<CodexQuestion> questions;
}

class CodexQuestion {
  const CodexQuestion({
    required this.id,
    required this.question,
    required this.options,
    this.header,
    this.isSecret = false,
    this.isOther = false,
  });
  factory CodexQuestion.fromJson(Json json) => CodexQuestion(
    id: _str(json['id']),
    question: _str(json['question']),
    header: json['header'] is String ? json['header'] as String : null,
    isSecret: json['isSecret'] == true,
    isOther: json['isOther'] == true,
    options: <CodexOption>[
      for (final option
          in (json['options'] is List ? json['options'] as List : <dynamic>[]))
        if (option is Json) CodexOption.fromJson(option),
    ],
  );
  final String id;
  final String question;
  final String? header;
  final bool isSecret;
  final bool isOther;
  final List<CodexOption> options;
}

class CodexOption {
  const CodexOption({required this.label, this.description});
  factory CodexOption.fromJson(Json json) => CodexOption(
    label: _str(json['label']),
    description: json['description'] is String
        ? json['description'] as String
        : null,
  );
  final String label;
  final String? description;
}

class CodexNotice {
  const CodexNotice(this.threadId);
  final String? threadId;
}
