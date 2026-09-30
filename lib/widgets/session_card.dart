import 'package:flutter/material.dart';

import '../models/protocol.dart';
import '../theme/app_theme.dart';
import '../util/format.dart';

String statusLabel(SessionStatus status) {
  switch (status) {
    case SessionStatus.starting:
      return '启动中';
    case SessionStatus.running:
      return '运行中';
    case SessionStatus.waiting:
      return '等待授权';
    case SessionStatus.idle:
      return '空闲';
    case SessionStatus.error:
      return '出错';
    case SessionStatus.closed:
      return '已结束';
  }
}

IconData statusIcon(SessionStatus status) {
  switch (status) {
    case SessionStatus.starting:
    case SessionStatus.running:
      return Icons.bolt_rounded;
    case SessionStatus.waiting:
      return Icons.front_hand_rounded;
    case SessionStatus.idle:
      return Icons.chat_bubble_outline_rounded;
    case SessionStatus.error:
      return Icons.error_outline_rounded;
    case SessionStatus.closed:
      return Icons.check_circle_outline_rounded;
  }
}

/// One row in the home list.
class SessionCard extends StatelessWidget {
  const SessionCard({
    super.key,
    required this.session,
    required this.onTap,
    this.onLongPress,
  });

  final SessionInfo session;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = AppTheme.statusColor(scheme, session.status.name);
    final radius = BorderRadius.circular(16);
    final waiting = session.pending > 0;

    return Material(
      color: waiting ? scheme.tertiaryContainer : scheme.surfaceContainerLow,
      borderRadius: radius,
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 12, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: session.status == SessionStatus.running
                    ? Padding(
                        padding: const EdgeInsets.all(11),
                        child: CircularProgressIndicator(
                          strokeWidth: 2.2,
                          color: color,
                        ),
                      )
                    : Icon(statusIcon(session.status), color: color, size: 21),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      session.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: waiting ? scheme.onTertiaryContainer : null,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      shortenPath(session.cwd),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTheme.mono(
                        11.5,
                        color: scheme.onSurfaceVariant,
                        height: 1.3,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: <Widget>[
                        _Pill(
                          text: waiting
                              ? '${session.pending} 个请求待授权'
                              : statusLabel(session.status),
                          color: waiting ? scheme.tertiary : color,
                          strong: waiting,
                        ),
                        _Pill(
                          text: PermissionModes.label(session.mode),
                          color: scheme.onSurfaceVariant,
                        ),
                        if (session.costUsd > 0)
                          _Pill(
                            text: formatCost(session.costUsd),
                            color: scheme.onSurfaceVariant,
                          ),
                        Text(
                          formatRelative(session.updatedAt),
                          style: TextStyle(
                            fontSize: 11,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.text, required this.color, this.strong = false});

  final String text;
  final Color color;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: strong ? color : color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: strong ? Theme.of(context).colorScheme.onTertiary : color,
        ),
      ),
    );
  }
}
