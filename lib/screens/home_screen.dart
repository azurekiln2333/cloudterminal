import 'package:flutter/material.dart';

import '../models/protocol.dart';
import '../state/appearance.dart';
import '../state/remote_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/appearance_sheet.dart';
import '../widgets/history_sheet.dart';
import '../widgets/new_session_sheet.dart';
import '../widgets/session_card.dart';
import 'session_screen.dart';

/// Connection status plus the list of sessions on the paired PC.
class HomeScreen extends StatelessWidget {
  const HomeScreen({
    super.key,
    required this.controller,
    required this.appearance,
  });

  final RemoteController controller;
  final Appearance appearance;

  void _open(BuildContext context, SessionInfo session) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SessionScreen(
          controller: controller,
          view: controller.view(session),
        ),
      ),
    );
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
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final scheme = Theme.of(context).colorScheme;
        final sessions = controller.sessions;
        final online = controller.isOnline;

        return Scaffold(
          appBar: AppBar(
            titleSpacing: 16,
            title: _Title(controller: controller),
            actions: <Widget>[
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
                      ? _Empty(online: online)
                      : ListView.separated(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
                          itemCount: sessions.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 10),
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
  const _Empty({required this.online});

  final bool online;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ListView(
      // Scrollable so pull-to-refresh works on the empty state too.
      padding: const EdgeInsets.fromLTRB(32, 96, 32, 32),
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
