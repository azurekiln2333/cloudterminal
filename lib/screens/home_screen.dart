import 'dart:async';

import 'package:flutter/material.dart';

import '../models/protocol.dart';
import '../state/appearance.dart';
import '../state/codex_catalog.dart';
import '../state/herdr_controller.dart';
import '../state/remote_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/appearance_sheet.dart';
import '../widgets/history_sheet.dart';
import '../widgets/new_session_sheet.dart';
import '../widgets/session_card.dart';
import '../widgets/workspace_sidebar.dart';
import 'codex_screen.dart';
import 'herdr_screen.dart';
import 'session_screen.dart';

/// Connection status plus the list of sessions on the paired PC.
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.controller,
    required this.appearance,
  });

  final RemoteController controller;
  final Appearance appearance;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final _scaffold = GlobalKey<ScaffoldState>();
  final _navigator = GlobalKey<NavigatorState>();
  late final CodexCatalog _catalog = CodexCatalog(widget.controller);
  late final HerdrController _herdr = HerdrController(widget.controller);
  String? _selectedThread;
  String? _selectedSession;
  bool _herdrOpen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // HomeScreen is the long-lived owner of the controller and its sidebar shows
    // live workspace counts, so it keeps one watcher for the whole session. The
    // screens render their own rows and add their own watcher on top.
    _herdr.watch();
    unawaited(_herdr.refresh());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The Herdr watchdog polls the desktop; stop it while the app is not in the
    // foreground and re-read once on return, so a tab created on the PC while
    // the phone was locked is already there when the user looks at the screen.
    if (state == AppLifecycleState.resumed) {
      _herdr.watch();
      unawaited(_herdr.refresh());
    } else {
      _herdr.unwatchAll();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _herdr.unwatch();
    _catalog.dispose();
    _herdr.dispose();
    super.dispose();
  }

  Widget? _navigationButton(BuildContext context) =>
      MediaQuery.sizeOf(context).width < 1000
      ? IconButton(
          tooltip: '工作空间',
          onPressed: () => _scaffold.currentState?.openDrawer(),
          icon: const Icon(Icons.menu_rounded),
        )
      : null;

  void _home() {
    _scaffold.currentState?.closeDrawer();
    _navigator.currentState?.popUntil((route) => route.isFirst);
    setState(() {
      _selectedThread = null;
      _selectedSession = null;
      _herdrOpen = false;
    });
  }

  /// Herdr is a sibling destination that keeps the existing session/Codex flow
  /// untouched; returning from it restores the previous home view.
  ///
  /// [workspaceId] pre-selects a workspace (the drawer's workspace rows), so the
  /// tap lands on the thing the user pointed at instead of the general page.
  void _openHerdr({String? workspaceId}) {
    _scaffold.currentState?.closeDrawer();
    _navigator.currentState?.popUntil((route) => route.isFirst);
    setState(() {
      _selectedThread = null;
      _selectedSession = null;
      _herdrOpen = true;
    });
    _navigator.currentState!
        .push(
          MaterialPageRoute<void>(
            builder: (context) => HerdrScreen(
              controller: widget.controller,
              herdr: _herdr,
              initialWorkspaceId: workspaceId,
              navigationButton: _navigationButton(context),
            ),
          ),
        )
        .then((_) {
          if (mounted && !_navigator.currentState!.canPop()) {
            setState(() => _herdrOpen = false);
          }
        });
  }

  void _open({SessionInfo? session, CodexThread? thread}) {
    _home();
    setState(() {
      _selectedThread = thread?.id;
      _selectedSession = session?.id;
    });
    _navigator.currentState!
        .push(
          MaterialPageRoute<void>(
            builder: (context) => thread != null
                ? CodexScreen(
                    controller: widget.controller,
                    thread: thread,
                    navigationButton: _navigationButton(context),
                  )
                : SessionScreen(
                    controller: widget.controller,
                    view: widget.controller.view(session!),
                    herdr: _herdr,
                    navigationButton: _navigationButton(context),
                  ),
          ),
        )
        .then((_) {
          if (mounted && !_navigator.currentState!.canPop()) {
            setState(() {
              _selectedThread = null;
              _selectedSession = null;
            });
          }
        });
  }

  Future<void> _history() async {
    _scaffold.currentState?.closeDrawer();
    final resumed = await showHistorySheet(context, widget.controller);
    if (resumed != null && mounted) _open(session: resumed);
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 1000;
    final sidebar = WorkspaceSidebar(
      controller: widget.controller,
      catalog: _catalog,
      herdr: _herdr,
      onHome: _home,
      onHistory: _history,
      onHerdr: _openHerdr,
      onHerdrWorkspace: (workspace) =>
          _openHerdr(workspaceId: workspace.workspaceId),
      onThread: (thread) => _open(thread: thread),
      onSession: (session) => _open(session: session),
      onCloseDrawer: () => _scaffold.currentState?.closeDrawer(),
      showClose: !wide,
      selectedThreadId: _selectedThread,
      selectedSessionId: _selectedSession,
      herdrSelected: _herdrOpen,
    );
    return Scaffold(
      key: _scaffold,
      drawer: wide ? null : sidebar,
      body: Row(
        children: <Widget>[
          if (wide) SizedBox(width: 320, child: sidebar),
          if (wide) const VerticalDivider(width: 1),
          Expanded(
            child: NavigatorPopHandler<Object?>(
              onPopWithResult: (_) => _navigator.currentState!.maybePop(),
              child: Navigator(
                key: _navigator,
                onGenerateRoute: (_) => MaterialPageRoute<void>(
                  builder: (context) => _ManagedHomeScreen(
                    controller: widget.controller,
                    appearance: widget.appearance,
                    herdr: _herdr,
                    navigationButton: _navigationButton(context),
                    onOpen: (session) => _open(session: session),
                    onHerdr: _openHerdr,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ManagedHomeScreen extends StatelessWidget {
  const _ManagedHomeScreen({
    required this.controller,
    required this.appearance,
    required this.onOpen,
    required this.onHerdr,
    this.herdr,
    this.navigationButton,
  });

  final RemoteController controller;
  final Appearance appearance;
  final ValueChanged<SessionInfo> onOpen;

  /// Opens the Herdr destination; drives the app-bar action and the empty
  /// state's shortcut, which is the only way into Herdr when no PTY session was
  /// ever created.
  final VoidCallback onHerdr;
  final HerdrController? herdr;
  final Widget? navigationButton;

  void _open(BuildContext context, SessionInfo session) {
    onOpen(session);
  }

  Future<void> _newSession(BuildContext context) async {
    final created = await showNewSessionSheet(context, controller);
    if (created != null && context.mounted) _open(context, created);
  }

  Future<void> _history(BuildContext context) async {
    final resumed = await showHistorySheet(context, controller);
    if (resumed != null && context.mounted) _open(context, resumed);
  }

  Future<void> _confirmUnpair(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.link_off_rounded),
        title: const Text('断开配对？'),
        content: const Text('这台手机会忘记电脑的连接信息。电脑上正在运行的会话不受影响，之后可以用新的配对码重新连接。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('断开'),
          ),
        ],
      ),
    );
    if (ok == true) await controller.unpair();
  }

  Future<void> _sessionMenu(BuildContext context, SessionInfo session) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              leading: const Icon(Icons.open_in_new_rounded),
              title: const Text('打开'),
              onTap: () => Navigator.of(context).pop('open'),
            ),
            if (session.isBusy)
              ListTile(
                leading: const Icon(Icons.stop_circle_outlined),
                title: const Text('停止当前任务'),
                onTap: () => Navigator.of(context).pop('interrupt'),
              ),
            ListTile(
              leading: Icon(
                Icons.delete_outline_rounded,
                color: Theme.of(context).colorScheme.error,
              ),
              title: Text(session.isClosed ? '从列表移除' : '结束会话'),
              onTap: () => Navigator.of(context).pop('close'),
            ),
          ],
        ),
      ),
    );
    if (!context.mounted || action == null) return;
    try {
      switch (action) {
        case 'open':
          _open(context, session);
        case 'interrupt':
          await controller.interrupt(session.id);
        case 'close':
          await controller.closeSession(session.id);
      }
    } on RemoteException catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable?>[controller, herdr]),
      builder: (context, _) {
        final scheme = Theme.of(context).colorScheme;
        final sessions = controller.sessions;
        final online = controller.isOnline;
        // Reads only: the page itself explains an unavailable bridge, so the
        // entry must not disappear just because control is not established.
        final herdrBrowsable = herdr?.canBrowse ?? false;

        return Scaffold(
          appBar: AppBar(
            leading: navigationButton,
            titleSpacing: 16,
            title: _Title(controller: controller),
            actions: <Widget>[
              if (herdrBrowsable)
                IconButton(
                  tooltip: 'Herdr 工作区',
                  onPressed: onHerdr,
                  icon: const Icon(Icons.grid_view_rounded),
                ),
              IconButton(
                tooltip: '历史会话',
                onPressed: online ? () => _history(context) : null,
                icon: const Icon(Icons.history_rounded),
              ),
              PopupMenuButton<String>(
                tooltip: '更多',
                onSelected: (value) {
                  switch (value) {
                    case 'appearance':
                      showAppearanceSheet(context, appearance);
                    case 'reconnect':
                      controller.connect();
                    case 'unpair':
                      _confirmUnpair(context);
                  }
                },
                itemBuilder: (context) => const <PopupMenuEntry<String>>[
                  PopupMenuItem<String>(
                    value: 'appearance',
                    child: ListTile(
                      leading: Icon(Icons.palette_outlined),
                      title: Text('外观'),
                    ),
                  ),
                  PopupMenuItem<String>(
                    value: 'reconnect',
                    child: ListTile(
                      leading: Icon(Icons.refresh_rounded),
                      title: Text('重新连接'),
                    ),
                  ),
                  PopupMenuItem<String>(
                    value: 'unpair',
                    child: ListTile(
                      leading: Icon(Icons.link_off_rounded),
                      title: Text('断开配对'),
                    ),
                  ),
                ],
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: online ? () => _newSession(context) : null,
            backgroundColor: online ? null : scheme.surfaceContainerHighest,
            foregroundColor: online ? null : scheme.onSurfaceVariant,
            icon: const Icon(Icons.add_rounded),
            label: const Text('新建会话'),
          ),
          body: Column(
            children: <Widget>[
              _ConnectionBanner(controller: controller),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: () async {
                    if (online) {
                      await controller.refreshSessions().catchError((_) {});
                    } else {
                      controller.reconnectNow();
                    }
                  },
                  child: sessions.isEmpty
                      ? _Empty(
                          online: online,
                          herdr: herdr,
                          onHerdr: onHerdr,
                        )
                      : ListView.separated(
                          // Bottom padding clears the FAB *and* the phone's
                          // gesture bar, so the last session is not parked under
                          // the system inset.
                          padding: EdgeInsets.fromLTRB(
                            16,
                            12,
                            16,
                            96 + MediaQuery.viewPaddingOf(context).bottom,
                          ),
                          itemCount: sessions.length,
                          separatorBuilder: (_, _) =>
                              const SizedBox(height: 10),
                          itemBuilder: (context, i) {
                            final s = sessions[i];
                            return SessionCard(
                              key: ValueKey<String>(s.id),
                              session: s,
                              onTap: () => _open(context, s),
                              onLongPress: () => _sessionMenu(context, s),
                            );
                          },
                        ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Title extends StatelessWidget {
  const _Title({required this.controller});

  final RemoteController controller;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (label, color) = switch (controller.phase) {
      ConnectionPhase.online => ('已连接', scheme.primary),
      ConnectionPhase.connecting => ('正在连接…', scheme.outline),
      ConnectionPhase.agentOffline => ('电脑离线', scheme.tertiary),
      ConnectionPhase.authFailed => ('配对失效', scheme.error),
      ConnectionPhase.disconnected => ('网络断开', scheme.error),
      ConnectionPhase.unpaired => ('未配对', scheme.outline),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(controller.agentName),
        const SizedBox(height: 2),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 7,
              height: 7,
              decoration: BoxDecoration(shape: BoxShape.circle, color: color),
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _ConnectionBanner extends StatelessWidget {
  const _ConnectionBanner({required this.controller});

  final RemoteController controller;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final phase = controller.phase;

    final content = switch (phase) {
      ConnectionPhase.agentOffline => (
        Icons.desktop_access_disabled_rounded,
        '电脑上的 agent 没有连接到服务器。确认电脑开着并运行了 npm run agent。',
        '重试',
        false,
      ),
      ConnectionPhase.authFailed => (
        Icons.key_off_rounded,
        controller.lastError ?? '配对已失效，请重新配对。',
        '重新配对',
        true,
      ),
      ConnectionPhase.disconnected => (
        Icons.cloud_off_rounded,
        controller.lastError ?? '连不上服务器，正在自动重试…',
        '立即重试',
        false,
      ),
      _ => null,
    };

    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      child: content == null
          ? const SizedBox(width: double.infinity)
          : Container(
              width: double.infinity,
              margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
              decoration: BoxDecoration(
                color: content.$4
                    ? scheme.errorContainer
                    : scheme.secondaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: <Widget>[
                  Icon(
                    content.$1,
                    size: 20,
                    color: content.$4
                        ? scheme.onErrorContainer
                        : scheme.onSecondaryContainer,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      content.$2,
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.4,
                        color: content.$4
                            ? scheme.onErrorContainer
                            : scheme.onSecondaryContainer,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: content.$4
                        ? controller.unpair
                        : controller.reconnectNow,
                    child: Text(content.$3),
                  ),
                ],
              ),
            ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({
    required this.online,
    this.herdr,
    this.onHerdr,
  });

  final bool online;
  final HerdrController? herdr;
  final VoidCallback? onHerdr;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final workspaces = herdr?.canBrowse == true
        ? herdr!.workspaces.length
        : 0;
    final herdrReady = onHerdr != null && workspaces > 0;
    return ListView(
      // Scrollable so pull-to-refresh works on the empty state too.
      padding: EdgeInsets.fromLTRB(
        32,
        72,
        32,
        32 + MediaQuery.viewPaddingOf(context).bottom,
      ),
      children: <Widget>[
        Icon(
          online ? Icons.forum_outlined : Icons.hourglass_empty_rounded,
          size: 56,
          color: scheme.outline,
        ),
        const SizedBox(height: 16),
        Text(
          online ? '还没有会话' : '等待连接',
          textAlign: TextAlign.center,
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Text(
          online
              ? '点右下角新建一个，或者从右上角的历史里继续电脑上的会话。'
              : '连接上电脑后，这里会列出正在运行的 Claude 会话。',
          textAlign: TextAlign.center,
          style: TextStyle(color: scheme.onSurfaceVariant, height: 1.5),
        ),
        if (herdrReady) ...<Widget>[
          const SizedBox(height: 20),
          // Herdr lives on the desktop and needs no PTY session, so a phone with
          // an empty session list must still be able to walk straight into it.
          // Making the user create a session first was the dead end: nothing in
          // the empty state said Herdr was already running next door.
          OutlinedButton.icon(
            onPressed: onHerdr,
            icon: const Icon(Icons.grid_view_rounded),
            label: Text('打开 Herdr（$workspaces 个工作区）'),
          ),
        ],
        const SizedBox(height: 8),
        Text(
          '长按会话可以停止或结束它。',
          textAlign: TextAlign.center,
          style: AppTheme.mono(11, color: scheme.outline),
        ),
      ],
    );
  }
}
