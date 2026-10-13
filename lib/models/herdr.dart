// Typed mirror of the `herdr_*` part of server/src/shared/protocol.ts.
//
// Parsing stays lenient in the same way as protocol.dart: unknown fields are
// ignored, unknown agent statuses become [HerdrAgentStatus.unknown], and missing
// optionals are simply absent. A newer desktop agent must never crash the app.

import 'protocol.dart';

/// Lifecycle as Herdr reports it. `idle` and `done` both mean "ready for input".
enum HerdrAgentStatus { idle, working, blocked, done, unknown }

HerdrAgentStatus parseHerdrAgentStatus(Object? value) {
  for (final status in HerdrAgentStatus.values) {
    if (status.name == value) return status;
  }
  return HerdrAgentStatus.unknown;
}

/// Which buffer [HerdrController.read] pulls from.
enum HerdrReadSource {
  visible('visible', '可见屏幕'),
  recent('recent', '最近输出'),
  recentUnwrapped('recent-unwrapped', '最近输出(去折行)'),
  detection('detection', '检测快照');

  const HerdrReadSource(this.wire, this.label);

  /// Wire value expected by the desktop agent and the Herdr CLI.
  final String wire;
  final String label;
}

/// Why Herdr cannot be driven, kept together so the UI can explain it.
class HerdrAvailability {
  const HerdrAvailability({
    required this.available,
    required this.installed,
    required this.serverRunning,
    required this.canControl,
    this.version,
    this.protocol,
    this.socket,
    this.reason,
  });

  factory HerdrAvailability.fromJson(Json json) => HerdrAvailability(
    available: json['available'] == true,
    installed: json['installed'] == true,
    serverRunning: json['serverRunning'] == true,
    canControl: json['canControl'] == true,
    version: json['version'] is String ? json['version'] as String : null,
    protocol: json['protocol'] is num
        ? (json['protocol'] as num).toInt()
        : null,
    socket: json['socket'] is String ? json['socket'] as String : null,
    reason: json['reason'] is String ? json['reason'] as String : null,
  );

  final bool available;
  final bool installed;
  final bool serverRunning;
  final bool canControl;
  final String? version;
  final int? protocol;
  final String? socket;
  final String? reason;

  String get summary {
    if (canControl) return 'Herdr ${version ?? ''}'.trim();
    return reason ?? 'Herdr 暂不可用';
  }
}

class HerdrWorkspace {
  const HerdrWorkspace({
    required this.workspaceId,
    required this.label,
    required this.number,
    required this.focused,
    required this.agentStatus,
    required this.paneCount,
    required this.tabCount,
    this.activeTabId,
  });

  factory HerdrWorkspace.fromJson(Json json) => HerdrWorkspace(
    workspaceId: _str(json['workspaceId']),
    label: _str(json['label']),
    number: _int(json['number']),
    focused: json['focused'] == true,
    agentStatus: parseHerdrAgentStatus(json['agentStatus']),
    paneCount: _int(json['paneCount']),
    tabCount: _int(json['tabCount']),
    activeTabId: json['activeTabId'] is String
        ? json['activeTabId'] as String
        : null,
  );

  final String workspaceId;
  final String label;
  final int number;
  final bool focused;
  final HerdrAgentStatus agentStatus;
  final int paneCount;
  final int tabCount;
  final String? activeTabId;

  String get displayLabel => label.isEmpty ? workspaceId : label;

  /// Canonical wire field names. Kept next to the parser so a rename on either
  /// side of the wire breaks the cross-layer test instead of shipping silently.
  Map<String, dynamic> toJson() => <String, dynamic>{
    'workspaceId': workspaceId,
    'label': label,
    'number': number,
    'focused': focused,
    'agentStatus': agentStatus.name,
    'paneCount': paneCount,
    'tabCount': tabCount,
    if (activeTabId != null) 'activeTabId': activeTabId,
  };
}

class HerdrTab {
  const HerdrTab({
    required this.tabId,
    required this.workspaceId,
    required this.label,
    required this.number,
    required this.focused,
    required this.agentStatus,
    required this.paneCount,
  });

  factory HerdrTab.fromJson(Json json) => HerdrTab(
    tabId: _str(json['tabId']),
    workspaceId: _str(json['workspaceId']),
    label: _str(json['label']),
    number: _int(json['number']),
    focused: json['focused'] == true,
    agentStatus: parseHerdrAgentStatus(json['agentStatus']),
    paneCount: _int(json['paneCount']),
  );

  final String tabId;
  final String workspaceId;
  final String label;
  final int number;
  final bool focused;
  final HerdrAgentStatus agentStatus;
  final int paneCount;
}

class HerdrScroll {
  const HerdrScroll({
    required this.offsetFromBottom,
    required this.maxOffsetFromBottom,
    required this.viewportRows,
  });

  factory HerdrScroll.fromJson(Json json) => HerdrScroll(
    offsetFromBottom: _int(json['offsetFromBottom']),
    maxOffsetFromBottom: _int(json['maxOffsetFromBottom']),
    viewportRows: _int(json['viewportRows']),
  );

  final int offsetFromBottom;
  final int maxOffsetFromBottom;
  final int viewportRows;
}

class HerdrPane {
  const HerdrPane({
    required this.paneId,
    required this.workspaceId,
    required this.tabId,
    required this.cwd,
    required this.focused,
    required this.terminalTitle,
    this.agent,
    this.agentStatus,
    this.name,
    this.interactiveReady,
    this.scroll,
  });

  factory HerdrPane.fromJson(Json json) => HerdrPane(
    paneId: _str(json['paneId']),
    workspaceId: _str(json['workspaceId']),
    tabId: _str(json['tabId']),
    cwd: _str(json['cwd']),
    focused: json['focused'] == true,
    terminalTitle: _str(json['terminalTitle']),
    agent: json['agent'] is String && (json['agent'] as String).isNotEmpty
        ? json['agent'] as String
        : null,
    agentStatus: json['agent'] is String
        ? parseHerdrAgentStatus(json['agentStatus'])
        : null,
    name: json['name'] is String ? json['name'] as String : null,
    interactiveReady: json['interactiveReady'] == true ? true : null,
    scroll: json['scroll'] is Json
        ? HerdrScroll.fromJson(json['scroll'] as Json)
        : null,
  );

  final String paneId;
  final String workspaceId;
  final String tabId;
  final String cwd;
  final bool focused;
  final String terminalTitle;
  final String? agent;
  final HerdrAgentStatus? agentStatus;
  final String? name;
  final bool? interactiveReady;
  final HerdrScroll? scroll;

  /// Only an idle shell can host a newly started agent.
  bool get hostsAgent => agent != null && agent!.isNotEmpty;

  /// What `agent prompt` / `send-keys` should target.
  String get agentTarget => (name != null && name!.isNotEmpty) ? name! : paneId;
}

class HerdrAgent {
  const HerdrAgent({
    required this.target,
    required this.paneId,
    required this.workspaceId,
    required this.tabId,
    required this.cwd,
    required this.agentKind,
    required this.status,
    required this.focused,
    required this.terminalTitle,
    this.name,
    this.interactiveReady,
    this.completionSeq,
    this.stateChangeSeq,
  });

  factory HerdrAgent.fromJson(Json json) => HerdrAgent(
    target: _str(json['target']),
    paneId: _str(json['paneId']),
    workspaceId: _str(json['workspaceId']),
    tabId: _str(json['tabId']),
    cwd: _str(json['cwd']),
    agentKind: _str(json['agentKind']),
    status: parseHerdrAgentStatus(json['status']),
    focused: json['focused'] == true,
    terminalTitle: _str(json['terminalTitle']),
    name: json['name'] is String ? json['name'] as String : null,
    interactiveReady: json['interactiveReady'] == true ? true : null,
    completionSeq: json['completionSeq'] is num
        ? (json['completionSeq'] as num).toInt()
        : null,
    stateChangeSeq: json['stateChangeSeq'] is num
        ? (json['stateChangeSeq'] as num).toInt()
        : null,
  );

  final String target;
  final String paneId;
  final String workspaceId;
  final String tabId;
  final String cwd;
  final String agentKind;
  final HerdrAgentStatus status;
  final bool focused;
  final String terminalTitle;
  final String? name;
  final bool? interactiveReady;
  final int? completionSeq;
  final int? stateChangeSeq;

  String get displayName =>
      (name != null && name!.isNotEmpty) ? name! : '$agentKind · $paneId';

  Map<String, dynamic> toJson() => <String, dynamic>{
    'target': target,
    'paneId': paneId,
    'workspaceId': workspaceId,
    'tabId': tabId,
    'cwd': cwd,
    'agentKind': agentKind,
    'status': status.name,
    'focused': focused,
    'terminalTitle': terminalTitle,
    if (name != null) 'name': name,
    if (interactiveReady != null) 'interactiveReady': interactiveReady,
    if (completionSeq != null) 'completionSeq': completionSeq,
    if (stateChangeSeq != null) 'stateChangeSeq': stateChangeSeq,
  };

  /// Herdr accepts input in `idle` and `done`; `blocked` needs the user to
  /// answer a dialog first and `unknown` is not provably ready.
  bool get canAcceptInput =>
      status == HerdrAgentStatus.idle || status == HerdrAgentStatus.done;

  bool get needsAttention =>
      status == HerdrAgentStatus.blocked || status == HerdrAgentStatus.done;
}

class HerdrLayout {
  const HerdrLayout({
    required this.workspaceId,
    required this.tabId,
    required this.zoomed,
    required this.area,
    required this.panes,
    required this.splits,
    this.focusedPaneId,
  });

  factory HerdrLayout.fromJson(Json json) => HerdrLayout(
    workspaceId: _str(json['workspaceId']),
    tabId: _str(json['tabId']),
    zoomed: json['zoomed'] == true,
    focusedPaneId: json['focusedPaneId'] is String
        ? json['focusedPaneId'] as String
        : null,
    area: HerdrRect.fromJson(
      json['area'] is Json ? json['area'] as Json : const <String, dynamic>{},
    ),
    panes: <HerdrLayoutPane>[
      for (final raw in (json['panes'] as List<dynamic>? ?? <dynamic>[]))
        if (raw is Json) HerdrLayoutPane.fromJson(raw),
    ],
    splits: <HerdrSplit>[
      for (final raw in (json['splits'] as List<dynamic>? ?? <dynamic>[]))
        if (raw is Json) HerdrSplit.fromJson(raw),
    ],
  );

  final String workspaceId;
  final String tabId;
  final bool zoomed;
  final String? focusedPaneId;
  final HerdrRect area;
  final List<HerdrLayoutPane> panes;
  final List<HerdrSplit> splits;
}

class HerdrRect {
  const HerdrRect({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  factory HerdrRect.fromJson(Json json) => HerdrRect(
    x: _int(json['x']),
    y: _int(json['y']),
    width: _int(json['width']),
    height: _int(json['height']),
  );

  final int x;
  final int y;
  final int width;
  final int height;
}

class HerdrLayoutPane {
  const HerdrLayoutPane({
    required this.paneId,
    required this.focused,
    required this.rect,
  });

  factory HerdrLayoutPane.fromJson(Json json) => HerdrLayoutPane(
    paneId: _str(json['paneId']),
    focused: json['focused'] == true,
    rect: HerdrRect.fromJson(
      json['rect'] is Json ? json['rect'] as Json : const <String, dynamic>{},
    ),
  );

  final String paneId;
  final bool focused;
  final HerdrRect rect;
}

class HerdrSplit {
  const HerdrSplit({
    required this.id,
    required this.direction,
    required this.ratio,
  });

  factory HerdrSplit.fromJson(Json json) => HerdrSplit(
    id: _str(json['id']),
    direction: _str(json['direction']),
    ratio: json['ratio'] is num ? (json['ratio'] as num).toDouble() : 0,
  );

  final String id;
  final String direction;
  final double ratio;
}

/// A pane's real screen text for one read source.
class HerdrOutput {
  const HerdrOutput({
    required this.paneId,
    required this.source,
    required this.text,
  });

  factory HerdrOutput.fromJson(Json json) => HerdrOutput(
    paneId: _str(json['paneId']),
    source: json['source'] is String
        ? HerdrReadSource.values.firstWhere(
            (s) => s.wire == json['source'],
            orElse: () => HerdrReadSource.visible,
          )
        : HerdrReadSource.visible,
    text: _str(json['text']),
  );

  final String paneId;
  final HerdrReadSource source;

  /// The agent's raw screen text, ANSI escapes and hard wraps included.
  ///
  /// This is the single source of truth for rendering: no consumer may rewrite
  /// it. Trailing whitespace, blank lines and the trailing newline are part of
  /// the terminal layout, not noise to trim.
  final String text;

  /// Whether there is no visible content at all. Only for empty-state checks;
  /// it never rewrites [text].
  bool get isBlank => text.trim().isEmpty;
}

/// A completed control action.
class HerdrActionReport {
  const HerdrActionReport({required this.action, required this.summary});

  factory HerdrActionReport.fromJson(Json json) => HerdrActionReport(
    action: _str(json['action']),
    summary: _str(json['summary']),
  );

  final String action;
  final String summary;
}

/// Builds the `herdr_act` payload. Kept in one place so the wire shape has a
/// single owner and the tests can assert it directly.
class HerdrActions {
  const HerdrActions._();

  static Json workspaceCreate({String? label, String? cwd, bool? focus}) =>
      _act('workspace_create', <String, dynamic>{
        'label': ?label,
        'cwd': ?cwd,
        'focus': ?focus,
      });

  static Json workspaceRename(String workspaceId, String label) => _act(
    'workspace_rename',
    <String, dynamic>{'workspaceId': workspaceId, 'label': label},
  );

  static Json workspaceFocus(String workspaceId) =>
      _act('workspace_focus', <String, dynamic>{'workspaceId': workspaceId});

  static Json workspaceClose(String workspaceId, {bool? group}) => _act(
    'workspace_close',
    <String, dynamic>{'workspaceId': workspaceId, 'group': ?group},
  );

  static Json tabCreate(
    String workspaceId, {
    String? label,
    String? cwd,
    bool? focus,
  }) => _act('tab_create', <String, dynamic>{
    'workspaceId': workspaceId,
    'label': ?label,
    'cwd': ?cwd,
    'focus': ?focus,
  });

  static Json tabRename(String tabId, String label) =>
      _act('tab_rename', <String, dynamic>{'tabId': tabId, 'label': label});

  static Json tabFocus(String tabId) =>
      _act('tab_focus', <String, dynamic>{'tabId': tabId});

  static Json tabClose(String tabId) =>
      _act('tab_close', <String, dynamic>{'tabId': tabId});

  static Json paneSplit(
    String paneId,
    String direction, {
    double? ratio,
    String? cwd,
    bool? focus,
  }) => _act('pane_split', <String, dynamic>{
    'paneId': paneId,
    'direction': direction,
    'ratio': ?ratio,
    'cwd': ?cwd,
    'focus': ?focus,
  });

  static Json paneFocus(String paneId) =>
      _act('pane_focus', <String, dynamic>{'paneId': paneId});

  static Json paneZoom(String paneId, {String mode = 'toggle'}) =>
      _act('pane_zoom', <String, dynamic>{'paneId': paneId, 'mode': mode});

  static Json paneRename(String paneId, {String? label}) =>
      _act('pane_rename', <String, dynamic>{'paneId': paneId, 'label': ?label});

  static Json paneClose(String paneId) =>
      _act('pane_close', <String, dynamic>{'paneId': paneId});

  static Json paneResize(String paneId, String direction, {double? amount}) =>
      _act('pane_resize', <String, dynamic>{
        'paneId': paneId,
        'direction': direction,
        'amount': ?amount,
      });

  static Json paneMoveToNewTab(String paneId, {String? label}) => _act(
    'pane_move',
    <String, dynamic>{'paneId': paneId, 'to': 'new_tab', 'label': ?label},
  );

  static Json paneMoveToNewWorkspace(String paneId, {String? label}) => _act(
    'pane_move',
    <String, dynamic>{'paneId': paneId, 'to': 'new_workspace', 'label': ?label},
  );

  static Json agentStart(
    String name,
    String agentKind,
    String paneId, {
    List<String>? args,
  }) => _act('agent_start', <String, dynamic>{
    'name': name,
    'agentKind': agentKind,
    'paneId': paneId,
    'args': ?args,
  });

  static Json agentRename(String target, {String? name}) =>
      _act('agent_rename', <String, dynamic>{'target': target, 'name': ?name});

  static Json agentFocus(String target) =>
      _act('agent_focus', <String, dynamic>{'target': target});

  static Json _act(String kind, Json fields) => <String, dynamic>{
    'kind': kind,
    ...fields,
  };
}

/// Agent kinds Herdr supports, in the order shown in the UI.
const List<String> herdrAgentKinds = <String>[
  'pi',
  'claude',
  'codex',
  'gemini',
  'cursor',
  'devin',
  'agy',
  'cline',
  'omp',
  'mastracode',
  'opencode',
  'copilot',
  'kimi',
  'kiro',
  'droid',
  'amp',
  'grok',
  'hermes',
  'kilo',
  'qodercli',
  'qwen',
  'letta',
  'maki',
  'muse',
];

/// Logical keys the desktop agent accepts, grouped for the control row.
const List<(String, String)> herdrKeys = <(String, String)>[
  ('enter', 'Enter'),
  ('esc', 'Esc'),
  ('tab', 'Tab'),
  ('shift+tab', '⇧Tab'),
  ('ctrl+c', 'Ctrl-C'),
  ('ctrl+d', 'Ctrl-D'),
  ('ctrl+l', 'Ctrl-L'),
  ('ctrl+r', 'Ctrl-R'),
  ('ctrl+u', 'Ctrl-U'),
  ('up', '↑'),
  ('down', '↓'),
  ('left', '←'),
  ('right', '→'),
];

// Same helpers as protocol.dart; kept local so this file stays self-contained.
String _str(Object? v) => v is String ? v : '';
int _int(Object? v) => v is num ? v.toInt() : 0;
