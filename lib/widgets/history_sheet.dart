import 'package:flutter/material.dart';

import '../models/protocol.dart';
import '../state/remote_controller.dart';
import '../theme/app_theme.dart';
import '../util/format.dart';

/// Past Claude Code sessions on the PC (including ones started in the
/// terminal). Picking one resumes it; returns the new live session.
Future<SessionInfo?> showHistorySheet(
  BuildContext context,
  RemoteController controller,
) {
  return showModalBottomSheet<SessionInfo>(
    context: context,
    isScrollControlled: true,
    builder: (context) => FractionallySizedBox(
      heightFactor: 0.85,
      child: _HistorySheet(controller: controller),
    ),
  );
}

class _HistorySheet extends StatefulWidget {
  const _HistorySheet({required this.controller});

  final RemoteController controller;

  @override
  State<_HistorySheet> createState() => _HistorySheetState();
}

class _HistorySheetState extends State<_HistorySheet> {
  late Future<List<HistoryItem>> _items = widget.controller.history();
  String? _resuming;

  Future<void> _resume(HistoryItem item) async {
    final cwd = item.cwd;
    if (cwd == null || cwd.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('这条记录没有工作目录，无法恢复')),
      );
      return;
    }
    setState(() => _resuming = item.sessionId);
    try {
      final session = await widget.controller
          .createSession(cwd: cwd, resume: item.sessionId);
      if (mounted) Navigator.of(context).pop(session);
    } on RemoteException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _resuming = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return SafeArea(
      top: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
            child: Text('历史会话', style: theme.textTheme.titleLarge),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Text(
              '电脑上的 Claude Code 会话（包括在终端里开的），点一下继续。',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          const Divider(),
          Expanded(
            child: FutureBuilder<List<HistoryItem>>(
              future: _items,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text('${snapshot.error}'),
                        TextButton(
                          onPressed: () => setState(
                            () => _items = widget.controller.history(),
                          ),
                          child: const Text('重试'),
                        ),
                      ],
                    ),
                  );
                }
                final items = snapshot.data!;
                if (items.isEmpty) {
                  return Center(
                    child: Text(
                      '还没有历史会话',
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  );
                }
                return ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: items.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 2),
                  itemBuilder: (context, i) {
                    final item = items[i];
                    final busy = _resuming == item.sessionId;
                    return ListTile(
                      enabled: _resuming == null,
                      leading: busy
                          ? const SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Icon(Icons.history_rounded, color: scheme.primary),
                      title: Text(
                        item.summary,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${item.cwd == null ? '' : baseName(item.cwd!)} · '
                        '${formatRelative(item.lastModified)}',
                        style: AppTheme.mono(
                          11.5,
                          color: scheme.onSurfaceVariant,
                          height: 1.3,
                        ),
                      ),
                      onTap: () => _resume(item),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
