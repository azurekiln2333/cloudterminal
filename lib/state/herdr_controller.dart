import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/herdr.dart';
import '../models/protocol.dart' show Json;
import 'remote_controller.dart';

/// Caches Herdr state for the UI and serialises control actions.
///
/// Live structure and output arrive through pushes. Explicit refreshes cover
/// first open, reconnect and mutations; a lightweight watchdog is the fallback
/// when the desktop event connection is unavailable. Actions are guarded by
/// [_inFlight] so a double tap cannot send the same mutating command twice.
class HerdrController extends ChangeNotifier implements HerdrPushSink {
  HerdrController(this._remote, {this.watchdogInterval = _defaultWatchdog}) {
    _wasOnline = _remote.isOnline;
    _remote.addListener(_onRemote);
    // Receives `herdr_pane_output` / `herdr_structure` pushes from the relay.
    _remote.setHerdrSink(this);
    // The link may already be up when this controller is built (it outlives any
    // single screen), in which case the transition hook below never fires and
    // the first probe would wait for a manual refresh.
    //
    // Deferred to after the frame: this constructor often runs inside a build
    // (a `late final` field initialiser in a screen), and refresh notifies
    // synchronously.
    if (_wasOnline) {
      scheduleMicrotask(() {
        if (!_disposed) unawaited(refresh());
      });
    }
  }

  /// How often the watchdog re-reads Herdr while the link is up.
  ///
  /// This is now a **correctness fallback**, not the mechanism: live structure
  /// changes arrive as socket pushes within tens of milliseconds. The tick exists
  /// because the push stream cannot prove itself — Herdr's `events.subscribe` is
  /// silent when a subscription is invalid, so a dead stream looks identical to a
  /// quiet one. 12 s is slow enough to be invisible next to the push and fast
  /// enough that a broken stream is noticed long before the user gives up.
  static const Duration _defaultWatchdog = Duration(seconds: 12);

  /// Injectable so tests can drive the tick deterministically.
  final Duration watchdogInterval;

  final RemoteController _remote;
  bool _disposed = false;
  bool _wasOnline = false;
  Timer? _watchdog;
  int _watchers = 0;

  /// Whether the watchdog is currently armed. Exposed for tests.
  bool get watching => _watchdog != null;

  /// How many live screens are watching. Exposed for tests.
  int get watchers => _watchers;

  // -------------------------------------------------------------------------
  // Live pane content
  // -------------------------------------------------------------------------

  /// Screen text pushed for each pane, keyed by pane id.
  ///
  /// This mirrors the agent's `lastText`: the agent sends a prefix length plus a
  /// suffix, and the receiver validates the prefix against this before applying.
  /// A mismatch (a missed push) falls back to a full replace rather than
  /// corrupting the screen.
  final Map<String, String> _paneTexts = <String, String>{};

  /// Wire format of the last push per pane (`ansi` normally).
  final Map<String, String> _paneFormats = <String, String>{};

  /// Pane whose output is currently pushed, or null.
  ///
  /// This is the **subscription** state, not the user's choice: it goes null when
  /// the screen stops watching (leaving the page, or clearing the selection).
  String? _watchedPaneId;

  /// The pane the user last chose, remembered across screens.
  ///
  /// Deliberately separate from [_watchedPaneId]. Leaving the screen clears the
  /// subscription but must not forget *what* was being watched: the controller
  /// outlives the screen, so reopening it has to restore the same pane. Conflating
  /// the two is what made the pane view fall back to the plain PTY for good after
  /// one visit — the subscription was dropped, the "user picked" flag was not, and
  /// the follow-the-desktop path was then permanently suppressed with nothing left
  /// to restore. One of the two states must own the choice; here it is this field.
  String? _preferredPaneId;

  String? get watchedPaneId => _watchedPaneId;

  /// The workspace that owns [paneId], derived from the id itself.
  ///
  /// Herdr ids are `<workspace>:p<slot>` (`wJ:pX`), so ownership is knowable
  /// without consulting a cache. Used to decide which listing has the authority to
  /// invalidate a remembered pane.
  static String? workspaceOfPaneId(String paneId) {
    final colon = paneId.indexOf(':');
    if (colon <= 0) return null;
    return paneId.substring(0, colon);
  }

  /// The pane the user's last explicit choice points at, if any.
  String? get preferredPaneId => _preferredPaneId;

  /// True when the remembered pane came from an explicit tap rather than from
  /// tracking the desktop. While true, the screen must not re-follow the desktop's
  /// focus: the tap is the stronger signal.

  /// Raw screen text last received for [paneId], or empty.
  String paneText(String paneId) => _paneTexts[paneId] ?? '';

  /// Wire format of the last push for [paneId]; `ansi` unless told otherwise.
  String paneFormat(String paneId) => _paneFormats[paneId] ?? 'ansi';

  /// [paneId]'s current screen, prepared for replay into a terminal.
  ///
  /// Derived on read rather than stored, so the incremental `prefix`/`chunk`
  /// transport stays the only mutable state and the grid maths cannot drift from
  /// the text it describes.
  HerdrPaneSnapshot paneSnapshot(String paneId) =>
      HerdrPaneSnapshot.fromText(paneText(paneId), format: paneFormat(paneId));

  /// Asks the agent to stream [paneId], or to stop when null.
  ///
  /// Called by the terminal screen when the selected pane changes. Fire and
  /// forget: the agent replies with an ack, and the content arrives as pushes.
  /// [explicit] marks the choice as the user's own, which both remembers it for a
  /// future screen and stops the desktop's focus from overriding it.
  void watchPane(String? paneId, {bool explicit = false}) {
    final previousPane = _watchedPaneId;
    final previousPreference = _preferredPaneId;
    if (explicit) _preferredPaneId = paneId;
    _setSubscription(paneId);
    // Selection is local state, not a side effect of the next output frame. A
    // screen must rebuild for the new target before accepting the next input;
    // waiting for a push leaves its terminal bound to the previous pane.
    if (previousPane != _watchedPaneId ||
        previousPreference != _preferredPaneId) {
      _notify();
    }
  }

  /// Restores the remembered pane when a screen (re)opens, and returns it.
  ///
  /// The screen calls this instead of guessing: after leaving the page the
  /// subscription is gone but the choice is not, so this re-issues exactly one
  /// watch and gives the screen the id to render. Returns null when the user has
  /// not chosen a pane, leaving the screen free to follow the desktop.
  String? resumeWatching() {
    final paneId = _preferredPaneId;
    if (paneId == null) return null;
    _setSubscription(paneId);
    return paneId;
  }

  /// Stops streaming without forgetting the user's choice.
  ///
  /// Used when leaving the screen: the desktop must not keep reading a pane for a
  /// page nobody is on, but the choice has to survive so reopening restores it.
  void suspendWatching() {
    _setSubscription(null);
  }

  /// The actual subscribe/unsubscribe, with no effect on the remembered choice.
  void _setSubscription(String? paneId, {bool force = false}) {
    if (!force && _watchedPaneId == paneId) return;
    _watchedPaneId = paneId;
    // Drop buffered screens when no pane is streamed: a late push for a pane
    // nobody is showing must not render, and a later return starts from a clean
    // replay rather than a stale screen.
    if (paneId == null) {
      _paneTexts.clear();
      _paneFormats.clear();
    }
    if (!_remote.isOnline) return;
    unawaited(
      _remote.herdrWatch(paneId).catchError((Object _) {
        // A failed watch is not fatal: the structure pushes and the fallback
        // refresh still work, and the next pane switch retries.
      }),
    );
  }

  /// Re-sends the watch for the active subscription after a reconnect.
  ///
  /// Forced on purpose: the local id is unchanged, but the *desktop's* record of
  /// it was dropped with the old connection, so a value-equality short-circuit
  /// would leave the pane permanently silent. No-ops when nothing is streaming,
  /// so leaving a screen cannot trigger a background subscription on reconnect.
  void _resubscribeIfActive() {
    final paneId = _watchedPaneId;
    if (paneId == null) return;
    _setSubscription(paneId, force: true);
  }

  /// Applies a `herdr_pane_output` push.
  ///
  /// The payload is a **rendered screen snapshot**, not a raw PTY byte stream.
  /// Herdr paints a fixed grid; it never emits the cursor moves that would let a
  /// terminal reconstruct that grid from plain text. So the snapshot is rebuilt
  /// here as text and handed to the view. The display snapshot normalizes CRLF
  /// and confirmed row-end grid fill before replay at the phone's column count.
  /// Raw LF would step-indent each row; source columns must not force a desktop-
  /// sized mobile viewport. The original text remains intact in this cache.
  ///
  /// The transport stays incremental: `prefix`/`chunk` rebuild the same string
  /// that a full frame would carry, and an unchanged snapshot is not repainted.
  @override
  void applyPaneOutput({
    required String paneId,
    required bool reset,
    required int prefix,
    required String chunk,
    String format = 'ansi',
  }) {
    if (_disposed || paneId.isEmpty) return;
    final previous = _paneTexts[paneId] ?? '';
    // "You already have `prefix` characters; append this." The prefix is only
    // trustworthy when it matches what we hold: a missed or reordered push would
    // otherwise splice two different screens together.
    final usable = reset || prefix < 0 || prefix > previous.length
        ? -1
        : prefix;
    final next = usable < 0 ? chunk : previous.substring(0, usable) + chunk;
    if (next == previous) return;
    _paneTexts[paneId] = next;
    _paneFormats[paneId] = format;
    _notify();
  }

  /// Applies a `herdr_structure` push.
  ///
  /// Only the parts present changed. Notifies **only when something actually
  /// differs**, so a push cannot make the UI rebuild for nothing (the same quiet
  /// rule the watchdog uses).
  @override
  void applyStructure(Json message) {
    if (_disposed) return;
    final before = _structureSignature();
    final workspaces = message['workspaces'];
    if (workspaces is List) {
      _workspaces = <HerdrWorkspace>[
        for (final raw in workspaces)
          if (raw is Json) HerdrWorkspace.fromJson(raw),
      ];
      // Drop cached detail for workspaces that no longer exist so a closed
      // workspace cannot keep rendering as live.
      final live = _workspaces.map((w) => w.workspaceId).toSet();
      _tabs.removeWhere((id, _) => !live.contains(id));
      _panes.removeWhere((id, _) => !live.contains(id));
    }
    final agents = message['agents'];
    if (agents is List) {
      _agents = <HerdrAgent>[
        for (final raw in agents)
          if (raw is Json) HerdrAgent.fromJson(raw),
      ];
    }
    final workspaceId = message['workspaceId'] is String
        ? message['workspaceId'] as String
        : null;
    final tabs = message['tabs'];
    if (workspaceId != null && tabs is List) {
      _tabs[workspaceId] = <HerdrTab>[
        for (final raw in tabs)
          if (raw is Json) HerdrTab.fromJson(raw),
      ];
    }
    final panes = message['panes'];
    if (workspaceId != null && panes is List) {
      _panes[workspaceId] = <HerdrPane>[
        for (final raw in panes)
          if (raw is Json) HerdrPane.fromJson(raw),
      ];
      _reconcilePreferredPane(workspaceId);
    }
    // `_loaded` matters because the rows are gated on Herdr being usable; a push
    // proves it is, so a screen opened before the first probe still fills in.
    _loaded = true;
    if (_structureSignature() != before) _notify();
  }

  /// Drops a remembered/subscribed pane that the desktop says no longer exists.
  ///
  /// Only ever runs against an **authoritative, complete** pane list for the
  /// workspace that owns the pane — the pane id encodes its workspace (`wJ:pX`
  /// belongs to `wJ`), so a listing for any other workspace simply has no
  /// authority and returns immediately. That, plus the fact that this is called
  /// only from a full listing (a `herdr_structure` push or `loadWorkspace`),
  /// is what keeps a cold or partial cache from discarding a valid choice.
  ///
  /// Falling back matters because the remembered choice suppresses following the
  /// desktop: a stale id would pin the screen to a pane that can never produce
  /// output again.
  void _reconcilePreferredPane(String workspaceId) {
    final remembered = _preferredPaneId;
    if (remembered == null) return;
    if (workspaceOfPaneId(remembered) != workspaceId) return;
    final panes = _panes[workspaceId];
    if (panes == null) return;
    if (panes.any((p) => p.paneId == remembered)) return;
    _preferredPaneId = null;
    // Stop reading it too, otherwise the subscription would outlive the choice.
    if (_watchedPaneId == remembered) _setSubscription(null);
  }

  /// Everything the rows and the sidebar render, for change detection.
  String _structureSignature() {
    final buffer = StringBuffer(_listingSignature());
    for (final entry in _tabs.entries) {
      buffer.write('T${entry.key}:');
      for (final t in entry.value) {
        buffer.write(
          '${t.tabId}|${t.label}|${t.number}|${t.focused}|${t.agentStatus.name}|${t.paneCount};',
        );
      }
    }
    for (final entry in _panes.entries) {
      buffer.write('P${entry.key}:');
      for (final p in entry.value) {
        buffer.write(
          '${p.paneId}|${p.tabId}|${p.name}|${p.terminalTitle}|${p.focused}|${p.agentStatus?.name};',
        );
      }
    }
    return buffer.toString();
  }

  /// Exposed so screens can build actions without a second controller reference.
  RemoteController get remoteController => _remote;

  HerdrAvailability? _availability;
  List<HerdrWorkspace> _workspaces = const <HerdrWorkspace>[];
  List<HerdrAgent> _agents = const <HerdrAgent>[];
  final Map<String, List<HerdrTab>> _tabs = <String, List<HerdrTab>>{};
  final Map<String, List<HerdrPane>> _panes = <String, List<HerdrPane>>{};
  final Map<String, HerdrLayout> _layouts = <String, HerdrLayout>{};
  final Set<String> _inFlight = <String>{};
  bool _loading = false;
  bool _loaded = false;
  bool _probing = false;
  bool _probeFailed = false;
  String? _error;
  String? _explicitWorkspaceId;
  Future<void>? _inflightRefresh;

  HerdrAvailability? get availability => _availability;
  List<HerdrWorkspace> get workspaces => _workspaces;
  List<HerdrAgent> get agents => _agents;
  bool get loading => _loading;
  bool get loaded => _loaded;
  String? get error => _error;

  /// A probe is currently running; the UI shows "detecting" rather than a
  /// verdict while this is true.
  bool get probing => _probing;

  /// The bridge capability has been established: either the agent answered with
  /// an availability report, or the probe request itself failed. Until then the
  /// answer is genuinely *unknown* — which must never be rendered as "disabled".
  bool get probed => _availability != null || _probeFailed;

  /// True when the desktop agent reports Herdr and it is ready to be driven.
  ///
  /// Gates **mutating** actions only; browsing uses [canBrowse] so an
  /// unprobed or unavailable bridge can still be inspected.
  bool get canControl =>
      _remote.isOnline && (_availability?.available ?? false);

  /// True when the pair link is up, so the Herdr destination can be opened to
  /// show either real data or the reason it is unavailable.
  bool get canBrowse => _remote.isOnline;

  // -------------------------------------------------------------------------
  // Watchdog
  // -------------------------------------------------------------------------

  /// Start re-reading Herdr on an interval so desktop-side changes appear.
  ///
  /// Owned by the screens that render Herdr rows, not by the link: the timer
  /// must die with the widget tree, otherwise it outlives the screen and keeps
  /// polling (which widget tests catch as a leaked timer). Two screens can be
  /// mounted at once — a pane screen pushed over the Herdr list — so the ticks
  /// are reference-counted and the timer only stops when the last one leaves.
  ///
  /// Reading is request/response, so nothing else would tell the app that a tab
  /// was added on the PC: the rows would keep rendering the listing fetched when
  /// the screen was opened. A tick is skipped while a refresh or a mutating
  /// action is already running, so it can never race the state of a create or
  /// close the user just triggered.
  void watch() {
    if (_disposed) return;
    _watchers += 1;
    if (_watchers > 1 || _watchdog != null) return;
    _watchdog = Timer.periodic(watchdogInterval, (_) => _tick());
  }

  /// Release one watcher. Safe to call when none is registered.
  void unwatch() {
    if (_watchers > 0) _watchers -= 1;
    if (_watchers > 0) return;
    _watchdog?.cancel();
    _watchdog = null;
  }

  /// Stop every watcher regardless of how many screens are mounted.
  ///
  /// Used on app background and on link loss: those are facts about the whole
  /// session, not about one screen's lifetime.
  void unwatchAll() {
    _watchers = 0;
    _watchdog?.cancel();
    _watchdog = null;
  }

  void _tick() {
    if (_disposed || !canBrowse) return;
    // A refresh already in flight re-reads everything; a mutation in flight owns
    // the state until it finishes and refreshes itself.
    if (_inflightRefresh != null || _inFlight.isNotEmpty) return;
    unawaited(_refreshQuietly());
  }

  /// Pane the desktop reports as focused in the selected workspace, if loaded.
  ///
  /// Used to point the stream at whatever the desktop user is looking at. Null
  /// when nothing has been listed yet, which is why callers treat it as "no
  /// opinion" rather than "no pane".
  String? get focusedPaneId {
    final id = selectedWorkspaceId;
    if (id == null) return null;
    for (final pane in panes(id)) {
      if (pane.focused) return pane.paneId;
    }
    return null;
  }

  /// Set of action keys currently being executed; the UI disables them.
  Set<String> get inFlight => _inFlight;

  bool isBusy(String key) => _inFlight.contains(key);

  List<HerdrTab> tabs(String workspaceId) =>
      _tabs[workspaceId] ?? const <HerdrTab>[];

  List<HerdrPane> panes(String workspaceId) =>
      _panes[workspaceId] ?? const <HerdrPane>[];

  /// Workspace whose tabs/panes the terminal rows describe.
  ///
  /// An explicit choice (drawer or workspace chip) wins, because the user just
  /// asked for it and the desktop's focus may not have caught up yet. Otherwise
  /// it follows whatever the wire says is focused, so the rows point where the
  /// desktop user is without storing a second source of truth.
  String? get selectedWorkspaceId {
    final explicit = _explicitWorkspaceId;
    if (explicit != null && _workspaces.any((w) => w.workspaceId == explicit)) {
      return explicit;
    }
    for (final panes in _panes.values) {
      for (final pane in panes) {
        if (pane.focused) return pane.workspaceId;
      }
    }
    for (final tab in _tabs.values.expand((list) => list)) {
      if (tab.focused) return tab.workspaceId;
    }
    for (final workspace in _workspaces) {
      if (workspace.focused) return workspace.workspaceId;
    }
    return _workspaces.isEmpty ? null : _workspaces.first.workspaceId;
  }

  /// Tabs of [selectedWorkspaceId], or empty when nothing is selected.
  List<HerdrTab> get visibleTabs {
    final id = selectedWorkspaceId;
    return id == null ? const <HerdrTab>[] : tabs(id);
  }

  /// Panes of the focused tab in [selectedWorkspaceId].
  ///
  /// Falls back to every pane in the workspace when no tab is focused, so a
  /// single-tab workspace still lists its panes.
  List<HerdrPane> get visiblePanes {
    final id = selectedWorkspaceId;
    if (id == null) return const <HerdrPane>[];
    final all = panes(id);
    final focusedTab = _focusedTabId(id);
    if (focusedTab == null) return all;
    return all.where((pane) => pane.tabId == focusedTab).toList();
  }

  String? _focusedTabId(String workspaceId) {
    for (final tab in tabs(workspaceId)) {
      if (tab.focused) return tab.tabId;
    }
    return null;
  }

  /// Selects which workspace the terminal rows describe and loads it.
  ///
  /// This is the drawer's action; it does not focus the workspace on the
  /// desktop (that is [focusWorkspace]) so browsing stays read-only.
  void selectWorkspace(String workspaceId) {
    _explicitWorkspaceId = workspaceId;
    _notify();
    unawaited(loadWorkspace(workspaceId, force: true));
  }

  /// Focuses a workspace on the desktop and points the rows at it.
  Future<void> focusWorkspace(String workspaceId) async {
    selectWorkspace(workspaceId);
    await run(
      'workspace:$workspaceId',
      () => _remote.herdrAct(HerdrActions.workspaceFocus(workspaceId)),
    );
  }

  Future<void> focusTab(String tabId) =>
      run('tab:$tabId', () => _remote.herdrAct(HerdrActions.tabFocus(tabId)));

  Future<void> focusPane(String paneId) => run(
    'pane:$paneId',
    () => _remote.herdrAct(HerdrActions.paneFocus(paneId)),
  );

  /// Creates a tab in [workspaceId] and lets Herdr focus it.
  ///
  /// The new tab inherits the focused pane's cwd, which is what the desktop
  /// keybinding does; passing a cwd here would pin the tab to the workspace root
  /// and surprise a user who is deep inside a subdirectory.
  Future<void> createTab() async {
    final workspaceId = selectedWorkspaceId;
    if (workspaceId == null) return;
    await run(
      'tab-create:$workspaceId',
      () => _remote.herdrAct(HerdrActions.tabCreate(workspaceId)),
    );
  }

  HerdrLayout? layout(String paneId) => _layouts[paneId];

  /// Agents hosted in [workspaceId], most attention-needing first.
  List<HerdrAgent> agentsIn(String workspaceId) {
    final list = _agents.where((a) => a.workspaceId == workspaceId).toList()
      ..sort((a, b) {
        final na = a.needsAttention ? 1 : 0;
        final nb = b.needsAttention ? 1 : 0;
        if (na != nb) return nb - na;
        return a.paneId.compareTo(b.paneId);
      });
    return list;
  }

  /// How many live agents need the user (blocked or finished-unseen).
  int get attentionCount => _agents.where((a) => a.needsAttention).length;

  // -------------------------------------------------------------------------

  /// Tracks link transitions: probe once when the agent comes online (so the
  /// destination is usable without the user opening the page first), and clear
  /// cached state when it drops so stale Herdr data is never shown as live.
  void _onRemote() {
    final online = _remote.isOnline;
    if (online && !_wasOnline) {
      _wasOnline = true;
      // Not awaited: a listener cannot be async. refresh() is idempotent and
      // de-duplicated, so a concurrent page-init probe is harmless.
      unawaited(refresh());
      // The desktop drops a client's watch when its connection goes away
      // (`AgentCore.clientLeft`), so a reconnect must re-issue it or the pane
      // stays silent forever — `_watchedPaneId` still holds the id, which is
      // exactly why the value-equality guard in `_setSubscription` cannot be the
      // thing that restores it. Re-subscribe explicitly, and only when a screen is
      // actually streaming: a suspended selection must not subscribe in the
      // background while nobody is watching.
      _resubscribeIfActive();
    } else if (!online && _wasOnline) {
      _wasOnline = false;
      // Nothing to re-read while the link is down; a reconnecting screen (or the
      // next online transition) restarts it.
      unwatchAll();
      _loaded = false;
      _availability = null;
      _probeFailed = false;
      _error = null;
      // Drop the listings too, otherwise a stale agent/workspace count keeps
      // rendering as if it were live (the sidebar badge is not online-guarded).
      _workspaces = const <HerdrWorkspace>[];
      _agents = const <HerdrAgent>[];
      _tabs.clear();
      _panes.clear();
      _layouts.clear();
      _probing = false;
      _notify();
    }
  }

  /// Load availability plus the top-level listings.
  ///
  /// Concurrent non-forced calls share one request; `force` always issues a
  /// fresh probe because it expresses explicit user intent (pull-to-refresh).
  Future<void> refresh({bool force = false}) =>
      _refresh(force: force, quiet: false);

  /// Refresh without showing the loading state.
  ///
  /// Used by the watchdog: a background poll must be invisible unless it
  /// actually found a change, otherwise every tick rebuilds the rows (and a
  /// widget test's `pumpAndSettle` never settles).
  Future<void> _refreshQuietly() => _refresh(force: false, quiet: true);

  Future<void> _refresh({required bool force, required bool quiet}) {
    if (!_remote.isOnline) {
      _error = '电脑未连接';
      _notify();
      return Future<void>.value();
    }
    final pending = _inflightRefresh;
    if (!force && pending != null) return pending;
    final future = _doRefresh(force: force, quiet: quiet);
    _inflightRefresh = future;
    return future.whenComplete(() {
      if (identical(_inflightRefresh, future)) _inflightRefresh = null;
    });
  }

  /// A cheap equality key for the top-level listings and their counts.
  ///
  /// Used only to decide whether a quiet refresh is worth notifying about. It
  /// covers exactly what the rows and the sidebar render, so a changed `tabCount`
  /// or a new tab is never swallowed.
  String _listingSignature() {
    final buffer = StringBuffer();
    for (final w in _workspaces) {
      buffer.write(
        '${w.workspaceId}|${w.label}|${w.agentStatus.name}|${w.paneCount}|'
        '${w.tabCount}|${w.focused}|${w.activeTabId};',
      );
    }
    buffer.write('#');
    for (final a in _agents) {
      buffer.write('${a.target}|${a.paneId}|${a.status.name}|${a.focused};');
    }
    return buffer.toString();
  }

  Future<void> _doRefresh({required bool force, bool quiet = false}) async {
    final before = quiet ? _listingSignature() : '';
    if (!quiet) {
      _loading = true;
      _probing = true;
      _error = null;
      _notify();
    }
    try {
      final availability = await _remote.herdrInfo(force: force);
      _availability = availability;
      _probeFailed = false;
      if (!availability.available) {
        _workspaces = const <HerdrWorkspace>[];
        _agents = const <HerdrAgent>[];
        _tabs.clear();
        _panes.clear();
        _layouts.clear();
        _loaded = false;
        return;
      }
      final results = await Future.wait(<Future<Object>>[
        _remote.herdrWorkspaces(),
        _remote.herdrAgents(),
      ]);
      _workspaces = results[0] as List<HerdrWorkspace>;
      _agents = results[1] as List<HerdrAgent>;
      _loaded = true;
      // Drop cached detail for workspaces that no longer exist.
      final live = _workspaces.map((w) => w.workspaceId).toSet();
      _tabs.removeWhere((id, _) => !live.contains(id));
      _panes.removeWhere((id, _) => !live.contains(id));
    } on RemoteException catch (e) {
      // A probe that was interrupted by a disconnect must not resurrect the
      // capability verdict after _onRemote() already reset it: the link is
      // gone, so "unknown" is the honest state, not "failed".
      if (_remote.isOnline) {
        _error = _cleanHerdrError(e.message);
        _probeFailed = true;
      } else {
        _probeFailed = false;
        _error = null;
      }
    } finally {
      if (!quiet) {
        _loading = false;
        _probing = false;
        _notify();
      } else if (_listingSignature() != before) {
        // Something really changed on the desktop, so the rows must repaint.
        _loading = false;
        _notify();
      }
    }
    // The rows describe one workspace, so its tabs/panes have to exist for the
    // switchers to render at all. Loading them here (rather than leaving it to a
    // screen that may never ask) is what makes the terminal rows appear on open.
    //
    // Forced on purpose: a refresh means the caller believes something changed
    // (a tab was just created, a pane moved), and serving the cached listing is
    // exactly how the tab row went stale after `+`. Deliberately after the
    // notify, so the workspace list can paint first.
    if (_loaded) {
      final id = selectedWorkspaceId;
      if (id != null) await loadWorkspace(id, force: true, quiet: quiet);
    }
  }

  /// Load tabs and panes for one workspace (called when it is expanded).
  ///
  /// This is a read, so it follows the link rather than the write capability;
  /// otherwise an unprobed bridge left workspaces permanently collapsed.
  ///
  /// `quiet` is the watchdog path: identical listings must not repaint, or a
  /// background poll would rebuild the rows (and starve `pumpAndSettle`) every
  /// few seconds for no reason.
  Future<void> loadWorkspace(
    String workspaceId, {
    bool force = false,
    bool quiet = false,
  }) async {
    if (!canBrowse) return;
    if (!force &&
        _tabs.containsKey(workspaceId) &&
        _panes.containsKey(workspaceId)) {
      return;
    }
    final before = quiet ? _detailSignature(workspaceId) : '';
    try {
      final results = await Future.wait(<Future<Object>>[
        _remote.herdrTabs(workspaceId),
        _remote.herdrPanes(workspaceId),
      ]);
      _tabs[workspaceId] = results[0] as List<HerdrTab>;
      _panes[workspaceId] = results[1] as List<HerdrPane>;
      // This listing is authoritative for the workspace, so a remembered pane
      // that is gone can be cleared here too (not on a partial/cold cache).
      _reconcilePreferredPane(workspaceId);
      _notify();
    } on RemoteException catch (e) {
      _error = _cleanHerdrError(e.message);
    } finally {
      if (!quiet || _detailSignature(workspaceId) != before) _notify();
    }
  }

  /// Equality key for one workspace's tabs and panes, mirroring
  /// [_listingSignature] for the detail level the rows actually render.
  String _detailSignature(String workspaceId) {
    final buffer = StringBuffer();
    for (final t in tabs(workspaceId)) {
      buffer.write(
        '${t.tabId}|${t.label}|${t.number}|${t.focused}|'
        '${t.agentStatus.name}|${t.paneCount};',
      );
    }
    buffer.write('#');
    for (final p in panes(workspaceId)) {
      buffer.write(
        '${p.paneId}|${p.tabId}|${p.name}|${p.terminalTitle}|${p.focused}|'
        '${p.agentStatus?.name};',
      );
    }
    return buffer.toString();
  }

  Future<void> loadLayout(String paneId, {bool force = false}) async {
    if (!canBrowse || (!force && _layouts.containsKey(paneId))) return;
    try {
      _layouts[paneId] = await _remote.herdrLayout(paneId);
      _notify();
    } on RemoteException catch (e) {
      _error = _cleanHerdrError(e.message);
      _notify();
    }
  }

  Future<HerdrOutput> read(
    String paneId, {
    HerdrReadSource source = HerdrReadSource.visible,
    int lines = 200,
  }) => _remote.herdrRead(paneId, source: source, lines: lines);

  /// Writes text into [paneId]'s terminal, preserving clipboard [paste] intent.
  ///
  /// Terminal semantics, not `herdr_prompt`: this is "type these characters",
  /// which is what a shell pane and every TUI expect. Returns the action summary
  /// so the caller can surface it, and rethrows [RemoteException] so the screen
  /// can show the failure instead of silently dropping the keystroke.
  /// Clipboard writes let Herdr use the desktop pane's actual paste mode; raw
  /// typing and terminal keys keep their literal control bytes.
  Future<HerdrActionReport> sendText(
    String paneId,
    String text, {
    bool paste = false,
  }) => _remote.herdrSendText(paneId, text, paste: paste);

  /// Sends logical keys (e.g. `enter`, `esc`, `up`, `ctrl+c`) to [paneId].
  Future<HerdrActionReport> sendKeys(String paneId, List<String> keys) =>
      _remote.herdrSendKeys(paneId, keys);

  /// Submits [text] as a task to the agent hosted in [paneId].
  ///
  /// The explicit "send a task" action; deliberately separate from [sendText] so
  /// ordinary typing never becomes a prompt submission.
  Future<HerdrActionReport> prompt(String paneId, String text) =>
      _remote.herdrPrompt(paneId, text);

  /// Fire a mutating action once, refresh afterwards, and surface failures.
  ///
  /// The [key] identifies the UI control so it can be disabled while running;
  /// re-entrant calls for the same key are dropped rather than queued, which is
  /// what prevents a duplicate agent launch.
  Future<HerdrActionReport?> run(
    String key,
    Future<HerdrActionReport> Function() action, {
    bool refreshAfter = true,
  }) async {
    if (_inFlight.contains(key)) return null;
    _inFlight.add(key);
    _error = null;
    _notify();
    try {
      final report = await action();
      if (refreshAfter) await refresh();
      return report;
    } on RemoteException catch (e) {
      _error = _cleanHerdrError(e.message);
      rethrow;
    } finally {
      _inFlight.remove(key);
      _notify();
    }
  }

  /// Strip the stable wire prefix so the UI shows the actionable sentence.
  ///
  /// `herdr_failed:agent_blocked:agent 正在等待确认…` → `agent 正在等待确认…`
  static String _cleanHerdrError(String message) {
    var text = message;
    for (final prefix in const <String>[
      'herdr_unavailable',
      'herdr_invalid_argument',
      'herdr_failed',
    ]) {
      if (!text.startsWith('$prefix:')) continue;
      text = text.substring(prefix.length + 1);
      // A second segment is the raw Herdr code; drop it too.
      final colon = text.indexOf(':');
      if (colon > 0 && colon < 40 && !text.substring(0, colon).contains(' ')) {
        text = text.substring(colon + 1);
      }
      break;
    }
    return text;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unwatchAll();
    _remote.setHerdrSink(null);
    _paneTexts.clear();
    _paneFormats.clear();
    _remote.removeListener(_onRemote);
    super.dispose();
  }
}
