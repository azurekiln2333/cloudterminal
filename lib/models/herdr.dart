// Typed mirror of the `herdr_*` part of server/src/shared/protocol.ts.
//
// Parsing stays lenient in the same way as protocol.dart: unknown fields are
// ignored, unknown agent statuses become [HerdrAgentStatus.unknown], and missing
// optionals are simply absent. A newer desktop agent must never crash the app.

import 'package:xterm/utils.dart';

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

/// One pane screen, prepared for replay into a terminal emulator.
///
/// A Herdr `pane read` payload is a **flattened grid snapshot**, not a PTY byte
/// stream: the escape sequences that positioned it were consumed by Herdr, and
/// what comes back is text plus the spaces and line breaks that make up the
/// layout. Feeding that verbatim into a terminal goes wrong in two specific ways,
/// and this type exists to fix exactly those:
///
/// 1. A snapshot line ends in LF. A terminal treats LF as "move down one row",
///    not "down and to column 0", so every line would indent one step further
///    than the last. [replayText] normalises line endings to CRLF.
/// 2. The snapshot was painted for the desktop's column count. [columns] records
///    that source geometry as metadata; the mobile emulator still replays at the
///    phone's readable column count. Confirmed plain grid-padding is removed from
///    the display copy so it cannot wrap into additional blank rows.
///
/// Deliberately does not trim: trailing spaces and blank lines are part of a
/// terminal layout, and removing them is what broke alignment before.
class HerdrPaneSnapshot {
  const HerdrPaneSnapshot({
    required this.text,
    required this.columns,
    required this.rows,
    required this.replayText,
  });

  /// The snapshot exactly as received (escape sequences included, if `ansi`).
  final String text;

  /// Source column count, measured in terminal cells.
  final int columns;

  /// Row count, from the snapshot's line count.
  final int rows;

  /// [text] with line endings normalised so a terminal replays it as a full grid.
  ///
  /// Line endings become CRLF (a bare LF only moves the cursor down, which
  /// step-indents every line), **except a single trailing terminator, which is
  /// dropped**. A trailing CRLF would move the cursor past the last row and scroll
  /// the grid up by one, pushing the snapshot's first line into scrollback:
  /// `'a\nb\n'` in a 2-row grid showed only `b`, and `'x\n'` in a 1-row grid
  /// showed nothing at all. The emulator's grid, not the byte stream, is what the
  /// user sees, so replay must leave the cursor on the final row.
  final String replayText;

  /// Builds a snapshot from one push payload.
  ///
  /// [format] is the wire format; `ansi` payloads still carry colour, so the
  /// escapes are kept for the emulator rather than stripped here. [fallbackColumns]
  /// is used only when the text is empty and there is nothing to measure.
  factory HerdrPaneSnapshot.fromText(
    String text, {
    String format = 'ansi',
    int fallbackColumns = 80,
  }) {
    // Normalise endings first: line splitting and width measurement should see
    // the same lines the emulator will.
    final normalised = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final lines = normalised.split('\n');
    var widest = 0;
    for (final line in lines) {
      final width = displayWidth(line);
      if (width > widest) widest = width;
    }
    // A trailing newline yields one empty trailing element; the grid should not
    // grow a phantom row for it, but an all-empty screen still needs one row.
    final hadTrailingNewline = normalised.endsWith('\n');
    final rows = hadTrailingNewline ? lines.length - 1 : lines.length;
    final columnCount = widest > 0 ? widest : fallbackColumns;

    // Strip the host grid's right-edge fill before replaying, so a padded short line
    // cannot wrap into a phantom blank line at phone width. See [stripGridPadding]:
    // it is a no-op unless the rows agree on a grid edge.
    final unpadded = stripGridPadding(normalised);

    // Replay must not scroll. Two ways it otherwise would:
    //   * a trailing CRLF moves the cursor past the last row; and
    //   * content that exactly fills the last row leaves the emulator in
    //     "wrap pending", where the next CRLF wraps and scrolls as well.
    // Dropping the final terminator covers the first; reserving a column for the
    // wrap case is handled by [columns]'s caller staying at the source width and
    // by not emitting that terminator at all.
    var body = hadTrailingNewline
        ? unpadded.substring(0, unpadded.length - 1)
        : unpadded;
    // If the last line exactly fills the grid width, appending nothing is correct;
    // the CRLF we removed is what would have wrapped it. Normalise the rest.
    body = body.replaceAll('\n', '\r\n');
    return HerdrPaneSnapshot(
      text: text,
      columns: columnCount,
      rows: rows < 1 ? 1 : rows,
      replayText: body,
    );
  }

  /// True when this is the same screen as [other] (used to skip a repaint).
  bool sameScreenAs(HerdrPaneSnapshot other) => text == other.text;
}

/// Number of terminal cells [input] occupies.
///
/// Delegates to the **same** width table the vendored xterm renderer and buffer
/// use (`UnicodeV11.wcwidth`), rather than a local approximation: any divergence
/// would make a derived column count disagree with what actually gets painted, and
/// the row would then be wrapped or clipped. That table already covers CJK
/// double-width, combining marks (width 0) and the wide emoji ranges.
///
/// ANSI escape sequences occupy no cells and are skipped.
int displayWidth(String input) {
  var width = 0;
  var i = 0;
  while (i < input.length) {
    final code = input.codeUnitAt(i);
    if (code == 0x1b) {
      i = _skipEscape(input, i);
      continue;
    }
    if (code >= 0xd800 && code <= 0xdbff && i + 1 < input.length) {
      final low = input.codeUnitAt(i + 1);
      final rune = 0x10000 + ((code - 0xd800) << 10) + (low - 0xdc00);
      width += unicodeV11.wcwidth(rune);
      i += 2;
      continue;
    }
    width += unicodeV11.wcwidth(code);
    i += 1;
  }
  return width;
}

/// Shared width table instance (matching `Buffer`/`RenderTerminal`).
final UnicodeV11 unicodeV11 = UnicodeV11();

/// Skips one escape sequence starting at [start] (an ESC) and returns the next index.
int _skipEscape(String input, int start) {
  var i = start + 1;
  if (i >= input.length) return i;
  final next = input.codeUnitAt(i);
  if (next == 0x5b) {
    i += 1;
    while (i < input.length) {
      final c = input.codeUnitAt(i);
      i += 1;
      if (c >= 0x40 && c <= 0x7e) break;
    }
    return i;
  }
  if (next == 0x5d ||
      next == 0x50 ||
      next == 0x58 ||
      next == 0x5e ||
      next == 0x5f) {
    i += 1;
    while (i < input.length) {
      final c = input.codeUnitAt(i);
      if (c == 0x07) return i + 1;
      if (c == 0x1b &&
          i + 1 < input.length &&
          input.codeUnitAt(i + 1) == 0x5c) {
        return i + 2;
      }
      i += 1;
    }
    return i;
  }
  return i + 1;
}

/// Removes a host terminal's right-edge grid fill from a snapshot.
///
/// Herdr paints on a fixed grid, so a short line comes back padded with spaces out
/// to the grid edge. At the desktop's width those are invisible; reflowed at a
/// phone's ~40 columns they wrap onto their own line, which is the reported
/// "mysterious blank lines". A fully-filled blank row is the worst case: one empty
/// row at desktop width, two after wrapping.
///
/// The scan is a **token walk**, not a byte or suffix check, because ANSI makes the
/// raw tail ambiguous: `content + spaces + ESC[0m` ends in `m`, and spaces may
/// themselves be styled. Each row is walked with [_skipEscape], recording every
/// visible space's source span together with the SGR state in effect (background /
/// reverse video). A row is trimmed by deleting only the trailing run of **plain**
/// spaces — no background, no reverse — while every escape token is copied through
/// verbatim, including a trailing reset, which is stepped over but preserved.
///
/// Guards, all of which must hold or the text is returned untouched:
///
/// * **Group signature.** A padded screen agrees on an edge: two or more rows reach
///   the same width, that width is the widest thing on screen, and no row exceeds it.
/// * **Only plain trailing runs are removed.** A styled run is deliberate fill.
/// * **A content-filled row is left alone.** A row reaching the edge without a plain
///   trailing run has no fill to remove; it does not veto the other rows.
/// * Leading and interior spaces, real blank lines, and the original line endings
///   (including a trailing newline) are preserved.
String stripGridPadding(String text) {
  if (text.isEmpty) return text;
  final hadTrailingNewline = text.endsWith('\n');
  final lines = text.split('\n');
  // The element after a trailing newline is not a row.
  final rowCount = hadTrailingNewline ? lines.length - 1 : lines.length;
  if (rowCount < 2) return text;

  final scans = <_RowPad>[
    for (var i = 0; i < rowCount; i++) _scanRowPadding(lines[i]),
  ];

  // The grid edge is the **widest** row, not the most common one: a screen with many
  // short lines and only a couple of padded rows would otherwise elect a low edge and
  // then trip the overflow guard below into a no-op. The widest width must still be
  // supported by at least two rows, so a single coincidentally long line cannot
  // define the edge.
  //
  // Caveat, deliberately not solved here: without grid metadata there is no way to
  // tell a deliberate run of trailing spaces at the edge from real fill. That is why
  // only a width agreed on by two or more rows is treated as an edge, and why the
  // removal is limited to plain runs. It is a good heuristic, not a perfect
  // separation.
  final edge = scans.fold<int>(
    0,
    (best, scan) => scan.width > best ? scan.width : best,
  );
  if (edge <= 0) return text;
  final edgeCount = scans.where((scan) => scan.width == edge).length;
  if (edgeCount < 2) return text;

  final out = StringBuffer();
  for (var i = 0; i < rowCount; i++) {
    final scan = scans[i];
    // Only rows that reach the edge *and* end in a plain run are trimmed. A row that
    // fills the edge with content has nothing to remove and is copied as-is.
    final cut = scan.width == edge ? scan.plainTrailingStart : null;
    out.write(cut == null ? lines[i] : _cutRow(lines[i], cut));
    if (i < rowCount - 1) out.write('\n');
  }
  if (hadTrailingNewline) out.write('\n');
  return out.toString();
}

/// One row's padding analysis.
class _RowPad {
  const _RowPad({required this.width, required this.plainTrailingStart});

  /// Display width in cells (escapes contribute nothing).
  final int width;

  /// Source index where the trailing run of **plain** spaces begins, or null when
  /// the row does not end in such a run (styled fill, or content at the edge).
  ///
  /// A trailing SGR reset is stepped over while locating the run but stays in the
  /// output, so `content + spaces + ESC[0m` still reports the run's start.
  final int? plainTrailingStart;
}

/// Walks [row]'s tokens, tracking SGR state, and locates its plain padding run.
_RowPad _scanRowPadding(String row) {
  var i = 0;
  var width = 0;
  var background = false;
  var reverse = false;
  int? runStart;

  while (i < row.length) {
    final code = row.codeUnitAt(i);
    if (code == 0x1b) {
      final next = _skipEscape(row, i);
      final state = _applySgr(row.substring(i, next), background, reverse);
      background = state.$1;
      reverse = state.$2;
      i = next;
      continue;
    }
    final isHighSurrogate =
        code >= 0xd800 && code <= 0xdbff && i + 1 < row.length;
    final cellWidth = isHighSurrogate
        ? unicodeV11.wcwidth(
            0x10000 +
                ((code - 0xd800) << 10) +
                (row.codeUnitAt(i + 1) - 0xdc00),
          )
        : unicodeV11.wcwidth(code);
    if (code == 0x20 && !background && !reverse) {
      // A plain space extends (or starts) the candidate run.
      runStart ??= i;
    } else {
      // Anything visible or styled ends the candidate run.
      runStart = null;
    }
    width += cellWidth;
    i += isHighSurrogate ? 2 : 1;
  }

  return _RowPad(width: width, plainTrailingStart: runStart);
}

/// Removes the plain-space run starting at [cut], keeping escapes that follow it.
///
/// Escapes are re-appended in order so a trailing reset still reaches the emulator;
/// the padding cells themselves are dropped rather than re-emitted.
String _cutRow(String row, int cut) {
  final builder = StringBuffer()..write(row.substring(0, cut));
  var i = cut;
  while (i < row.length) {
    final code = row.codeUnitAt(i);
    if (code == 0x1b) {
      final next = _skipEscape(row, i);
      builder.write(row.substring(i, next));
      i = next;
      continue;
    }
    // Remaining plain spaces belonged to the run; anything visible is content.
    if (code == 0x20) {
      i += 1;
      continue;
    }
    builder.write(row.substring(i));
    break;
  }
  return builder.toString();
}

/// Applies a single SGR sequence to the running style state.
///
/// Returns the new `(background, reverse)` flags. Non-SGR escapes and unrecognised
/// sequences leave the state unchanged, so a colour change elsewhere on the row
/// cannot mark padding as styled.
///
/// Parameters are walked **by index, not mapped one-to-one**, because `38`/`48`/`58`
/// introduce extended colour forms whose payload is *not* a list of SGR opcodes:
/// `48;2;0;255;0` is an RGB background, and treating its `0` as a reset would wrongly
/// clear the background (and so drop styled fill); `38;5;7` has a colour index `7`
/// that must not be read as reverse video. Each such sequence consumes its payload
/// (`5;n` or `2;r;g;b`) whole — `48` sets the background, `38`/`58` do not touch the
/// tracked flags — and scanning continues after it, so later independent `0`/`49`/`27`
/// still apply normally.
(bool, bool) _applySgr(String escape, bool background, bool reverse) {
  // Shape: ESC [ <params> m
  if (escape.length < 3 ||
      escape.codeUnitAt(0) != 0x1b ||
      escape.codeUnitAt(1) != 0x5b ||
      !escape.endsWith('m')) {
    return (background, reverse);
  }
  final params = escape.substring(2, escape.length - 1);
  final values = params.split(';');
  var bg = background;
  var rev = reverse;
  var i = 0;
  while (i < values.length) {
    final part = values[i];
    final value = part.isEmpty ? 0 : int.tryParse(part);
    if (value == null) {
      i += 1;
      continue;
    }
    if (value == 38 || value == 48 || value == 58) {
      // Extended colour: consume its whole payload so the digits inside it are never
      // read as opcodes. Only `48` is a background; `38` (foreground) and `58`
      // (underline colour) leave the tracked flags as they were.
      final form = i + 1 < values.length ? int.tryParse(values[i + 1]) : null;
      if (form == 5) {
        i += 3; // 38/48/58 ; 5 ; n
      } else if (form == 2) {
        i += 5; // 38/48/58 ; 2 ; r ; g ; b
      } else {
        i += 1; // Unrecognised form: step past the introducer only.
      }
      if (value == 48) bg = true;
      continue;
    }
    if (value == 0) {
      bg = false;
      rev = false;
    } else if (value == 7) {
      rev = true;
    } else if (value == 27) {
      rev = false;
    } else if (value == 49) {
      bg = false;
    } else if ((value >= 40 && value <= 47) || (value >= 100 && value <= 107)) {
      // Standard and high-intensity background colours.
      bg = true;
    }
    i += 1;
  }
  return (bg, rev);
}
