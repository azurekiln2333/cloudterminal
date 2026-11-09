import 'package:flutter/material.dart';

import '../models/herdr.dart';
import '../models/protocol.dart';
import '../state/codex_catalog.dart';
import '../state/herdr_controller.dart';
import '../state/remote_controller.dart';
import '../util/format.dart';
import 'herdr_status.dart';

/// Same MD3 navigation content in a modal drawer and a persistent wide pane.
class WorkspaceSidebar extends StatelessWidget {
  const WorkspaceSidebar({
    super.key,
    required this.controller,
    required this.catalog,
    required this.herdr,
    required this.onHome,
    required this.onHistory,
    required this.onHerdr,
    this.onHerdrWorkspace,
    required this.onThread,
    required this.onSession,
    required this.onCloseDrawer,
    this.showClose = false,
    this.selectedThreadId,
    this.selectedSessionId,
    this.herdrSelected = false,
  });
  final RemoteController controller;
  final CodexCatalog catalog;
  final HerdrController herdr;
  final VoidCallback onHome;
  final VoidCallback onHistory;
  final VoidCallback onHerdr;

  /// Opens the Herdr page already pointing at [HerdrWorkspace].
  ///
  /// Tapping a workspace in the list moves the desktop focus (Herdr's own
  /// notion of "current workspace") *and* opens that workspace on the phone. The
  /// previous behaviour did only the first, so the tap changed something the
  /// phone user could not see.
  final ValueChanged<HerdrWorkspace>? onHerdrWorkspace;
  final ValueChanged<CodexThread> onThread;
  final ValueChanged<SessionInfo> onSession;

  /// Closes the surrounding drawer after an in-drawer action, so a tap does not
  /// leave the list covering the terminal it just switched.
  final VoidCallback onCloseDrawer;

  /// Shows an explicit close control in the header; true only when this instance
  /// is the modal drawer (a persistent wide sidebar must not offer it).
  final bool showClose;
  final String? selectedThreadId;
  final String? selectedSessionId;
  final bool herdrSelected;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge(<Listenable>[catalog, controller, herdr]),
    builder: (context, _) {
      final scheme = Theme.of(context).colorScheme;
      final codex = controller.agent?.codex;
      // Destination indices: 0 = sessions, 1 = Herdr, 2 = Claude history.
      final selectedIndex = herdrSelected
          ? 1
          : (selectedThreadId == null && selectedSessionId == null ? 0 : null);
      return NavigationDrawer(
        backgroundColor: scheme.surfaceContainerLow,
        selectedIndex: selectedIndex,
        onDestinationSelected: (i) => switch (i) {
          0 => onHome(),
          1 => onHerdr(),
          _ => onHistory(),        },
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(28, 20, 8, 12),
            child: Row(
              children: <Widget>[
                const Expanded(
                  child: Text(
                    '工作空间',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                  ),
                ),
                if (showClose)
                  IconButton(
                    tooltip: '关闭菜单',
                    onPressed: onCloseDrawer,
                    icon: const Icon(Icons.close_rounded),
                  ),
              ],
            ),
          ),
          const NavigationDrawerDestination(
            icon: Icon(Icons.terminal_rounded),
            label: Text('终端'),
          ),
          // Destinations must be direct children of NavigationDrawer: Flutter
          // assigns their indices by scanning this list, so they cannot be
          // wrapped in a Column/Row.
          NavigationDrawerDestination(
            icon: const Icon(Icons.grid_view_rounded),
            label: const Text('Herdr 工作区'),
            // Opens the management page (create / rename / close). Switching to
            // a workspace happens directly in the list below, so the common
            // case never leaves the drawer.
            enabled: herdr.canBrowse,
          ),
          // Live workspaces sit inside the drawer rather than on their own page.
          // Tapping one opens the Herdr page at that workspace; the rows there
          // lead to the pane terminal. Showing the list is a *read*, so it is
          // gated on `canBrowse`, not on the write capability.
          if (herdr.canBrowse)
            for (final workspace in herdr.workspaces)
              ListTile(
                dense: true,
                contentPadding: const EdgeInsets.only(left: 44, right: 16),
                leading: CircleAvatar(
                  radius: 4,
                  backgroundColor: herdrStatusColor(
                    scheme,
                    workspace.agentStatus,
                  ),
                ),
                title: Text(
                  workspace.label.isEmpty
                      ? workspace.workspaceId
                      : workspace.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '${workspace.tabCount} 标签 · ${workspace.paneCount} 面板',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: workspace.workspaceId == herdr.selectedWorkspaceId
                    ? Icon(Icons.check_rounded, size: 18, color: scheme.primary)
                    : null,
                onTap: () {
                  onCloseDrawer();
                  // Two effects, on purpose: the desktop switches to the
                  // workspace *and* the phone opens it. Switching only the
                  // desktop left the phone on an unchanged page, which read as a
                  // dead tap; opening only on the phone let the two screens
                  // disagree about where the user is.
                  herdr.focusWorkspace(workspace.workspaceId);
                  onHerdrWorkspace?.call(workspace);
                },
              ),
          if (_herdrHint(context) != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 0, 20, 8),
              child: Text(
                _herdrHint(context)!,
                style: TextStyle(
                  fontSize: 12,
                  color: herdr.canControl
                      ? scheme.tertiary
                      : scheme.onSurfaceVariant,
                ),
              ),
            ),
          NavigationDrawerDestination(
            icon: const Icon(Icons.history_rounded),
            label: const Text('Claude 历史'),
            enabled: controller.isOnline,
          ),
          for (final session in controller.sessions)
            ListTile(
              dense: true,
              contentPadding: const EdgeInsets.only(left: 28, right: 16),
              leading: Icon(
                session.isTerminal ? Icons.terminal : Icons.chat_bubble_outline,
                size: 18,
              ),
              selected: selectedSessionId == session.id,
              title: Text(
                session.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => onSession(session),
            ),
          const Divider(indent: 16, endIndent: 16),
          Padding(
            padding: const EdgeInsets.fromLTRB(28, 4, 16, 4),
            child: Row(
              children: <Widget>[
                const Expanded(
                  child: Text(
                    'Codex Desktop',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  tooltip: '刷新 Codex 项目',
                  icon: const Icon(Icons.refresh, size: 20),
                  onPressed:
                      controller.isOnline &&
                          codex?.available == true &&
                          !catalog.loading
                      ? () => catalog.loadProjects(refresh: true)
                      : null,
                ),
              ],
            ),
          ),
          if (codex?.available != true)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
              child: Text(
                codex?.reason ??
                    (controller.agent == null
                        ? '连接电脑后读取项目'
                        : '电脑端暂不支持 Codex 项目目录'),
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ),
          if (codex?.available == true) ...<Widget>[
            if (!codex!.canControl)
              Padding(
                padding: const EdgeInsets.fromLTRB(28, 0, 20, 12),
                child: Text(
                  codex.reason ?? '当前可查看历史，远程控制尚未连接',
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            _threads(context, null, '最近会话', const <String>[]),
            for (final project in catalog.projects)
              _threads(context, project.id, project.title, project.roots),
            if (catalog.loading)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              ),
            if (catalog.error != null)
              _error(
                catalog.error!,
                () => catalog.loadProjects(refresh: !catalog.loaded),
              ),
            if (catalog.loaded && catalog.projects.isEmpty)
              const Padding(
                padding: EdgeInsets.all(20),
                child: Text('没有已保存的项目'),
              ),
            if (catalog.nextCursor != null && !catalog.loading)
              TextButton(
                onPressed: () => catalog.loadProjects(),
                child: const Text('加载更多项目'),
              ),
          ],
          const SizedBox(height: 24),
        ],
      );
    },
  );

  /// Inline explanation for the Herdr destination, or null when it is ready
  /// and nothing needs attention.
  ///
  /// Distinguishes "not known yet" from "known unavailable": a missing
  /// availability report must never be rendered as a verdict about the desktop.
  String? _herdrHint(BuildContext context) {
    if (herdr.canControl) {
      return herdr.attentionCount > 0
          ? '${herdr.attentionCount} 个 agent 需要处理'
          : null;
    }
    // Offline is checked through the link, not `agent`: RemoteController keeps
    // the last agent info across a disconnect, so `agent != null` while
    // disconnected and the hint would sit on "detecting" forever.
    if (!controller.isOnline) return '连接电脑后读取 Herdr 工作区';    final availability = herdr.availability;
    // Probing or never probed: state the truth (unknown / in progress).
    if (availability == null) return '正在检测 Herdr…';
    if (availability.available) return null;
    return availability.summary;
  }

  Widget _threads(
    BuildContext context,
    String? projectId,
    String title,
    List<String> roots,
  ) {
    final list = catalog.threads(projectId);
    return ExpansionTile(
      key: PageStorageKey<String>('codex-project-${projectId ?? 'recent'}'),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      leading: Icon(
        projectId == null ? Icons.schedule : Icons.folder_outlined,
        size: 20,
      ),
      subtitle: roots.isEmpty
          ? null
          : Text(
              roots.join('\n'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11),
            ),
      onExpansionChanged: (expanded) {
        if (expanded && !list.loaded) catalog.loadThreads(projectId);
      },
      children: <Widget>[
        for (final thread in list.items)
          ListTile(
            dense: true,
            contentPadding: const EdgeInsets.only(left: 32, right: 16),
            selected: selectedThreadId == thread.id,
            title: Text(
              thread.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              formatRelative(thread.updatedAt),
              style: const TextStyle(fontSize: 11),
            ),
            onTap: () => onThread(thread),
          ),
        if (list.loading)
          const Padding(
            padding: EdgeInsets.all(12),
            child: Center(child: CircularProgressIndicator()),
          ),
        if (list.error != null)
          _error(
            list.error!,
            () => catalog.loadThreads(projectId, refresh: !list.loaded),
          ),
        if (list.loaded && list.items.isEmpty)
          const ListTile(dense: true, title: Text('没有会话')),
        if (list.nextCursor != null && !list.loading)
          TextButton(
            onPressed: () => catalog.loadThreads(projectId),
            child: const Text('加载更多会话'),
          ),
      ],
    );
  }

  Widget _error(String text, VoidCallback retry) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 20),
    child: Column(
      children: <Widget>[
        Text(text),
        TextButton(
          onPressed: controller.isOnline ? retry : null,
          child: const Text('重试'),
        ),
      ],
    ),
  );
}
