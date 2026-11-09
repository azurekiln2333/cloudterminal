import 'dart:async';

import 'package:flutter/material.dart';

import '../models/herdr.dart';
import '../state/herdr_controller.dart';
import '../state/remote_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/herdr_status.dart';
import 'herdr_terminal_screen.dart';

/// Lists the real Herdr workspaces, their tabs/panes and the agents inside.
///
/// Everything here comes from the paired PC's local Herdr installation; when it
/// is unavailable the screen explains why instead of showing invented data.
class HerdrScreen extends StatefulWidget {
  const HerdrScreen({
    super.key,
    required this.controller,
    required this.herdr,
    this.initialWorkspaceId,
    this.navigationButton,
  });

  final RemoteController controller;
  final HerdrController herdr;

  /// Workspace to open expanded and highlighted, so a tap in the drawer lands on
  /// the workspace the user pointed at instead of a page they must search.
  final String? initialWorkspaceId;
  final Widget? navigationButton;

  @override
  State<HerdrScreen> createState() => _HerdrScreenState();
}

class _HerdrScreenState extends State<HerdrScreen> {
  @override
  void initState() {
    super.initState();
    // A workspace chosen in the drawer is both selected (which workspace the
    // terminal rows describe) and expanded (so its panes are reachable at once).
    // Selection is a local read-only choice; it deliberately does not move the
    // desktop's focus, because the user asked to look, not to switch.
    //
    // Deferred to after the frame: `selectWorkspace` notifies synchronously, and
    // this route is still being built — notifying a listener mid-build throws.
    final initial = widget.initialWorkspaceId;
    // No watchdog here: this is the management page, refreshed on open and on
    // pull-to-refresh. The live rows live on the terminal screen and the live
    // workspace counts in the sidebar, which is where the watchdog belongs.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (initial != null) widget.herdr.selectWorkspace(initial);
      widget.herdr.refresh();
    });
  }

  /// Runs a Herdr action and surfaces its outcome. Accepts both a report
  /// (`herdr.run`) and a plain future (`onConfirm` from the close dialog).
  Future<void> _report(Future<Object?> Function() action) async {
    try {
      final result = await action();
      if (result is HerdrActionReport && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(result.summary)));
      }
    } on RemoteException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  Future<void> _confirmClose({
    required String title,
    required String body,
    required Future<Object?> Function() onConfirm,
  }) async {
    final scheme = Theme.of(context).colorScheme;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.warning_amber_rounded),
        title: Text(title),
        content: Text(body),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          // Error colours on purpose: this button cannot be undone, and a plain
          // filled button read like the safe primary action.
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: scheme.error,
              foregroundColor: scheme.onError,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('确认关闭'),
          ),
        ],
      ),
    );
    if (ok == true) await _report(onConfirm);
  }

  Future<void> _createWorkspace() async {
    final label = await showDialog<String>(
      context: context,
      builder: (context) => const _TextPromptDialog(
        title: '新建 Herdr 工作区',
        hint: '工作区名称（例如 cloudterminal）',
        confirmLabel: '创建',
      ),
    );
    if (label == null || !mounted) return;
    await _report(
      () => widget.herdr.run(
        'workspace_create',
        () => widget.controller.herdrAct(
          HerdrActions.workspaceCreate(label: label),
        ),
      ),
    );
  }

  Future<void> _renameWorkspace(HerdrWorkspace workspace) async {
    final label = await showDialog<String>(
      context: context,
      builder: (context) => _TextPromptDialog(
        title: '重命名工作区',
        hint: '新的工作区名称',
        initial: workspace.displayLabel,
        confirmLabel: '保存',
      ),
    );
    if (label == null || !mounted) return;
    await _report(
      () => widget.herdr.run(
        'workspace_rename:${workspace.workspaceId}',
        () => widget.controller.herdrAct(
          HerdrActions.workspaceRename(workspace.workspaceId, label),
        ),
      ),
    );
  }

  Future<void> _workspaceMenu(HerdrWorkspace workspace) async {
    // The focused pane (or the first one) is what "open terminal" would land on,
    // so the item is only offered when the workspace actually has one.
    final panes = widget.herdr.panes(workspace.workspaceId);
    final targetPane = panes.isEmpty
        ? null
        : panes.firstWhere(
            (pane) => pane.focused,
            orElse: () => panes.first,
          );
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (targetPane != null)
              ListTile(
                leading: const Icon(Icons.terminal_rounded),
                title: const Text('打开终端'),
                subtitle: Text(
                  targetPane.terminalTitle.isEmpty
                      ? targetPane.paneId
                      : targetPane.terminalTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => Navigator.of(context).pop('open'),
              ),
            ListTile(
              leading: const Icon(Icons.open_in_new_rounded),
              title: const Text('在电脑上切换'),
              onTap: () => Navigator.of(context).pop('focus'),
            ),
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline_rounded),
              title: const Text('重命名'),
              onTap: () => Navigator.of(context).pop('rename'),
            ),
            ListTile(
              leading: Icon(
                Icons.close_rounded,
                color: Theme.of(context).colorScheme.error,
              ),
              title: const Text('关闭工作区'),
              subtitle: const Text('其中所有面板和 agent 都会被结束'),
              onTap: () => Navigator.of(context).pop('close'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'open':
        if (targetPane != null) _openPane(workspace, targetPane);
      case 'focus':
        await _report(
          () => widget.herdr.run(
            'workspace_focus:${workspace.workspaceId}',
            () => widget.controller.herdrAct(
              HerdrActions.workspaceFocus(workspace.workspaceId),
            ),
          ),
        );
      case 'rename':
        await _renameWorkspace(workspace);
      case 'close':
        await _confirmClose(
          title: '关闭 ${workspace.displayLabel}？',
          body:
              'Herdr 会结束这个工作区里的 ${workspace.paneCount} 个面板及其中的 agent。'
              '这一步无法撤销。',
          onConfirm: () => widget.herdr.run(
            'workspace_close:${workspace.workspaceId}',
            () => widget.controller.herdrAct(
              HerdrActions.workspaceClose(workspace.workspaceId),
            ),
          ),
        );
    }
  }

  /// Opens the pane terminal for [pane].
  ///
  /// Ordering matters: the phone's own selection is set first and the desktop
  /// focus is requested second, so a slow or failed focus cannot stop the user
  /// from reaching the terminal they tapped. A failed focus is reported and the
  /// screen still opens — the pane output is a read.
  Future<void> _openPane(HerdrWorkspace workspace, HerdrPane pane) async {
    final herdr = widget.herdr;
    herdr.selectWorkspace(workspace.workspaceId);
    herdr.watchPane(pane.paneId, explicit: true);
    try {
      await herdr.focusPane(pane.paneId);
    } on RemoteException catch (e) {
      // Not fatal: the desktop may already be on this pane, and reading it does
      // not need the write capability.
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text('电脑端切换失败：${e.message}')));
      }
    }
    if (!mounted) return;
    await _pushPane(pane.paneId);
  }

  /// Pushes the pane terminal. Split out so the navigation target is stated in
  /// exactly one place.
  ///
  /// The pane screen gets **no** `navigationButton`: it is a pushed route, and
  /// handing it the drawer opener replaced Flutter's automatic back arrow with a
  /// control that opened the root drawer — the phone had no visible way out. The
  /// Drawer stays reachable one back-press away, on the screens that own it.
  Future<void> _pushPane(String paneId) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => HerdrTerminalScreen(
          controller: widget.controller,
          herdr: widget.herdr,
          paneId: paneId,
        ),
      ),
    );
    // Returning from a pane has to land on a current list: a pane or tab may have
    // been closed while it was open, and a stale row would offer a dead pane.
    if (mounted) unawaited(widget.herdr.refresh());
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge(<Listenable>[widget.herdr, widget.controller]),
    builder: (context, _) {
      final herdr = widget.herdr;
      final scheme = Theme.of(context).colorScheme;
      final availability = herdr.availability;
      final canControl = herdr.canControl;
      // Opening a pane is a read, so it follows the link rather than the write
      // capability; otherwise an unprobed bridge left every row dead.
      final canBrowse = herdr.canBrowse;
      // This page is always a pushed route (drawer workspace, app-bar action), so
      // it needs a way back. It used to receive the drawer button as `leading`,
      // which replaced the back arrow with a control that opened the *root*
      // drawer — the phone had no visible way out of the page.
      final canPop = Navigator.of(context).canPop();
      return Scaffold(
        appBar: AppBar(
          leading: canPop
              ? BackButton(onPressed: () => Navigator.of(context).pop())
              : widget.navigationButton,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text('Herdr 工作区'),
              Text(
                widget.controller.agentName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ),
          actions: <Widget>[
            if (canPop && widget.navigationButton != null)
              widget.navigationButton!,
            if (herdr.attentionCount > 0)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Chip(
                  visualDensity: VisualDensity.compact,
                  avatar: Icon(
                    Icons.front_hand_rounded,
                    size: 15,
                    color: scheme.tertiary,
                  ),
                  label: Text('${herdr.attentionCount} 待处理'),
                ),
              ),
            IconButton(
              tooltip: '刷新 Herdr 状态',
              // Refreshing is a read, so it must not require write capability.
              onPressed: canBrowse && !herdr.loading
                  ? () => herdr.refresh(force: true)
                  : null,
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        floatingActionButton: canControl
            ? FloatingActionButton.extended(
                onPressed: herdr.isBusy('workspace_create')
                    ? null
                    : _createWorkspace,
                icon: const Icon(Icons.add_rounded),
                label: const Text('新建工作区'),
              )
            : null,
        body: RefreshIndicator(
          onRefresh: () => herdr.refresh(force: true),
          child: Column(
            children: <Widget>[
              if (availability != null && !availability.available)
                _UnavailableBanner(availability: availability),
              if (herdr.error != null && availability?.available != false)
                _ErrorBanner(
                  message: herdr.error!,
                  onRetry: () => herdr.refresh(force: true),
                ),
              Expanded(
                child: _content(context, canControl, canBrowse, availability),
              ),
            ],
          ),
        ),
      );
    },
  );

  Widget _content(
    BuildContext context,
    bool canControl,
    bool canBrowse,
    HerdrAvailability? availability,
  ) {
    final herdr = widget.herdr;
    if (!widget.controller.isOnline) {
      return const _EmptyState(
        icon: Icons.desktop_access_disabled_rounded,
        title: '电脑未连接',
        body: '连接上电脑后这里会列出真实的 Herdr 工作区。',
      );
    }
    if (availability == null && (herdr.loading || !herdr.probed)) {
      return const Center(child: CircularProgressIndicator());
    }
    if (availability != null && !availability.available) {
      return _EmptyState(
        icon: Icons.extension_off_rounded,
        title: 'Herdr 不可用',
        body: availability.summary,
      );
    }
    final workspaces = herdr.workspaces;
    if (workspaces.isEmpty) {
      return ListView(
        padding: EdgeInsets.fromLTRB(
          32,
          72,
          32,
          32 + MediaQuery.viewPaddingOf(context).bottom,
        ),
        children: <Widget>[
          Icon(
            Icons.grid_view_rounded,
            size: 56,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: 16),
          const Text(
            '还没有 Herdr 工作区',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(
            canControl ? '点右下角新建一个，或直接在电脑上打开 Herdr 后下拉刷新。' : '连接上电脑后下拉刷新。',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      );
    }
    return ListView.builder(
      // The trailing padding clears the FAB and the gesture bar; without the
      // inset the last workspace sat under the system navigation area.
      padding: EdgeInsets.fromLTRB(
        12,
        8,
        12,
        96 + MediaQuery.viewPaddingOf(context).bottom,
      ),
      itemCount: workspaces.length,
      itemBuilder: (context, index) => _WorkspaceTile(
        key: ValueKey<String>(workspaces[index].workspaceId),
        workspace: workspaces[index],
        herdr: herdr,
        canControl: canControl,
        canBrowse: canBrowse,
        initiallyExpanded:
            workspaces[index].workspaceId == widget.initialWorkspaceId,
        onMenu: () => _workspaceMenu(workspaces[index]),
        onOpenPane: (pane) => _openPane(workspaces[index], pane),
        onReport: _report,
        onConfirmClose: _confirmClose,
      ),
    );
  }
}

class _WorkspaceTile extends StatefulWidget {
  const _WorkspaceTile({
    super.key,
    required this.workspace,
    required this.herdr,
    required this.canControl,
    required this.canBrowse,
    required this.onMenu,
    required this.onOpenPane,
    required this.onReport,
    required this.onConfirmClose,
    this.initiallyExpanded = false,
  });

  final HerdrWorkspace workspace;
  final HerdrController herdr;
  final bool canControl;

  /// Whether panes may be opened for reading; independent of [canControl].
  final bool canBrowse;
  final VoidCallback onMenu;
  final ValueChanged<HerdrPane> onOpenPane;
  final Future<void> Function(Future<Object?> Function()) onReport;
  final Future<void> Function({
    required String title,
    required String body,
    required Future<Object?> Function() onConfirm,
  })
  onConfirmClose;

  /// Opens expanded (a workspace picked in the drawer) so its panes are visible
  /// without a second tap.
  final bool initiallyExpanded;

  @override
  State<_WorkspaceTile> createState() => _WorkspaceTileState();
}

class _WorkspaceTileState extends State<_WorkspaceTile> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  void initState() {
    super.initState();
    if (_expanded) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          widget.herdr.loadWorkspace(widget.workspace.workspaceId);
        }
      });
    }
  }

  Future<void> _toggle() async {
    if (_expanded) {
      setState(() => _expanded = false);
      return;
    }
    setState(() => _expanded = true);
    await widget.herdr.loadWorkspace(widget.workspace.workspaceId);
  }

  Future<void> _createTab() async {
    final label = await showDialog<String>(
      context: context,
      builder: (context) => const _TextPromptDialog(
        title: '新建标签页',
        hint: '标签页名称（可留空）',
        confirmLabel: '创建',
        allowEmpty: true,
      ),
    );
    if (label == null || !mounted) return;
    final id = widget.workspace.workspaceId;
    await widget.onReport(
      () => widget.herdr.run(
        'tab_create:$id',
        () => widget.herdr.remoteController.herdrAct(
          HerdrActions.tabCreate(id, label: label.isEmpty ? null : label),
        ),
      ),
    );
    if (mounted) await widget.herdr.loadWorkspace(id, force: true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final workspace = widget.workspace;
    final busy = widget.herdr.isBusy(
      'workspace_focus:${workspace.workspaceId}',
    );
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Column(
        children: <Widget>[
          InkWell(
            onTap: _toggle,
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
              child: Row(
                children: <Widget>[
                  Container(
                    width: 40,
                    height: 40,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: herdrStatusColor(
                        scheme,
                        workspace.agentStatus,
                      ).withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '${workspace.number}',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: herdrStatusColor(scheme, workspace.agentStatus),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          workspace.displayLabel,
                          maxLines: 2,
                          softWrap: true,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: <Widget>[
                            HerdrStatusChip(status: workspace.agentStatus),
                            if (workspace.focused)
                              _MetaChip(
                                icon: Icons.visibility_rounded,
                                label: '电脑焦点',
                                color: scheme.primary,
                              ),
                            Text(
                              '${workspace.tabCount} 标签 · ${workspace.paneCount} 面板',
                              style: TextStyle(
                                fontSize: 11,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                            Text(
                              workspace.workspaceId,
                              style: AppTheme.mono(10.5, color: scheme.outline),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: '工作区操作',
                    onPressed: widget.canControl ? widget.onMenu : null,
                    icon: const Icon(Icons.more_vert_rounded),
                  ),
                  Icon(
                    _expanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    color: scheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
          if (busy) const LinearProgressIndicator(minHeight: 2),
          if (_expanded) ...<Widget>[
            const Divider(height: 1),
            _details(context),
          ],
        ],
      ),
    );
  }

  Widget _details(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final workspaceId = widget.workspace.workspaceId;
    final panes = widget.herdr.panes(workspaceId);
    final tabs = widget.herdr.tabs(workspaceId);
    final agents = widget.herdr.agentsIn(workspaceId);
    if (panes.isEmpty && widget.herdr.loading) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    // "No panes" and "the read failed" are different facts. Reporting the first
    // when the second is true sent the user looking for a workspace that was
    // there all along.
    final loadError = widget.herdr.error;
    if (panes.isEmpty && tabs.isEmpty && loadError != null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              loadError,
              style: TextStyle(color: scheme.error, height: 1.4),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () =>
                    widget.herdr.loadWorkspace(workspaceId, force: true),
                child: const Text('重试'),
              ),
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '面板',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: widget.canControl ? _createTab : null,
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('新建标签'),
              ),
            ],
          ),
          if (panes.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                '没有读取到面板',
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ),
          if (tabs.isEmpty)
            // Tabs were not reported (e.g. old agent): keep the flat pane list
            // instead of rendering an empty heading.
            for (final pane in panes)
              _PaneRow(
                pane: pane,
                canBrowse: widget.canBrowse,
                onTap: () => widget.onOpenPane(pane),
              )
          else ...<Widget>[
            Text(
              '标签页',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            for (final tab in tabs) ...<Widget>[
              _TabHeading(tab: tab),
              for (final pane in panes.where((p) => p.tabId == tab.tabId))
                _PaneRow(
                  pane: pane,
                  canBrowse: widget.canBrowse,
                  onTap: () => widget.onOpenPane(pane),
                ),
            ],
            // Panes whose tab id is not in the tab list must not disappear.
            for (final pane in panes.where(
              (p) => !tabs.any((tab) => tab.tabId == p.tabId),
            ))
              _PaneRow(
                pane: pane,
                canBrowse: widget.canBrowse,
                onTap: () => widget.onOpenPane(pane),
              ),
          ],
          if (agents.isNotEmpty) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              'Agents',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            for (final agent in agents)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: <Widget>[
                    HerdrStatusChip(status: agent.status, compact: true),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        agent.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12.5),
                      ),
                    ),
                    Text(
                      agent.paneId,
                      style: AppTheme.mono(10.5, color: scheme.outline),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _TabHeading extends StatelessWidget {
  const _TabHeading({required this.tab});

  final HerdrTab tab;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label = tab.label.isEmpty ? tab.tabId : tab.label;
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 2),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          Icon(Icons.tab_rounded, size: 15, color: scheme.onSurfaceVariant),
          Text(
            '$label (${tab.paneCount} 面板)',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: scheme.onSurface,
            ),
          ),
          HerdrStatusChip(status: tab.agentStatus, compact: true),
          if (tab.focused)
            _MetaChip(
              icon: Icons.visibility_rounded,
              label: '电脑焦点',
              color: scheme.primary,
            ),
        ],
      ),
    );
  }
}

/// Small icon + label annotation used for the focus marker and similar meta.
class _MetaChip extends StatelessWidget {
  const _MetaChip({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      Icon(icon, size: 14, color: color),
      const SizedBox(width: 3),
      Text(label, style: TextStyle(fontSize: 9.5, color: color)),
    ],
  );
}

class _PaneRow extends StatelessWidget {
  const _PaneRow({
    required this.pane,
    required this.canBrowse,
    required this.onTap,
  });

  final HerdrPane pane;

  /// Opening the pane only reads it, so an unprobed or unavailable bridge
  /// must still let the user look; writes are gated inside the pane screen.
  final bool canBrowse;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: canBrowse ? onTap : null,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Row(
          children: <Widget>[
            Icon(
              pane.hostsAgent
                  ? Icons.smart_toy_outlined
                  : Icons.terminal_rounded,
              size: 18,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    pane.terminalTitle.isEmpty
                        ? pane.paneId
                        : pane.terminalTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13),
                  ),
                  const SizedBox(height: 3),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: <Widget>[
                      Text(
                        pane.paneId,
                        style: AppTheme.mono(10.5, color: scheme.outline),
                      ),
                      if (pane.hostsAgent) ...<Widget>[
                        Text(
                          pane.name ?? pane.agent!,
                          style: TextStyle(
                            fontSize: 10.5,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        if (pane.agentStatus != null)
                          HerdrStatusChip(
                            status: pane.agentStatus!,
                            compact: true,
                          ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              size: 20,
              color: scheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

class _UnavailableBanner extends StatelessWidget {
  const _UnavailableBanner({required this.availability});

  final HerdrAvailability availability;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            availability.installed
                ? Icons.play_circle_outline_rounded
                : Icons.download_outlined,
            size: 20,
            color: scheme.onSecondaryContainer,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  availability.installed ? 'Herdr 已安装但未运行' : '这台电脑没有 Herdr',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: scheme.onSecondaryContainer,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  availability.summary,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.4,
                    color: scheme.onSecondaryContainer,
                  ),
                ),
                if (availability.version != null) ...<Widget>[
                  const SizedBox(height: 4),
                  Text(
                    '版本 ${availability.version}'
                    '${availability.protocol != null ? ' · 协议 ${availability.protocol}' : ''}',
                    style: AppTheme.mono(
                      11,
                      color: scheme.onSecondaryContainer,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: <Widget>[
          Icon(
            Icons.error_outline_rounded,
            size: 20,
            color: scheme.onErrorContainer,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.4,
                color: scheme.onErrorContainer,
              ),
            ),
          ),
          TextButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(32, 96, 32, 32),
      children: <Widget>[
        Icon(icon, size: 56, color: scheme.outline),
        const SizedBox(height: 16),
        Text(
          title,
          textAlign: TextAlign.center,
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Text(
          body,
          textAlign: TextAlign.center,
          style: TextStyle(color: scheme.onSurfaceVariant, height: 1.5),
        ),
      ],
    );
  }
}

/// Small single-field dialog used for create/rename flows.
class _TextPromptDialog extends StatefulWidget {
  const _TextPromptDialog({
    required this.title,
    required this.hint,
    required this.confirmLabel,
    this.initial = '',
    this.allowEmpty = false,
  });

  final String title;
  final String hint;
  final String confirmLabel;
  final String initial;
  final bool allowEmpty;

  @override
  State<_TextPromptDialog> createState() => _TextPromptDialogState();
}

class _TextPromptDialogState extends State<_TextPromptDialog> {
  late final TextEditingController _input = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  bool get _valid => widget.allowEmpty || _input.text.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(
      controller: _input,
      autofocus: true,
      decoration: InputDecoration(hintText: widget.hint),
      onChanged: (_) => setState(() {}),
      onSubmitted: (_) {
        if (_valid) Navigator.of(context).pop(_input.text.trim());
      },
    ),
    actions: <Widget>[
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: _valid
            ? () => Navigator.of(context).pop(_input.text.trim())
            : null,
        child: Text(widget.confirmLabel),
      ),
    ],
  );
}
