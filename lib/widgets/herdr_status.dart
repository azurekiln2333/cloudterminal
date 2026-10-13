import 'package:flutter/material.dart';

import '../models/herdr.dart';
import '../theme/app_theme.dart';
import '../util/format.dart';

/// Chinese label for a Herdr lifecycle status.
String herdrStatusLabel(HerdrAgentStatus status) {
  switch (status) {
    case HerdrAgentStatus.idle:
      return '空闲';
    case HerdrAgentStatus.working:
      return '工作中';
    case HerdrAgentStatus.blocked:
      return '等待确认';
    case HerdrAgentStatus.done:
      return '已完成';
    case HerdrAgentStatus.unknown:
      return '未知';
  }
}

/// Short explanation of what a status means for the user.
String herdrStatusHint(HerdrAgentStatus status) {
  switch (status) {
    case HerdrAgentStatus.idle:
      return '可以接收输入';
    case HerdrAgentStatus.working:
      return '正在执行任务';
    case HerdrAgentStatus.blocked:
      return '需要你在电脑上确认或回答';
    case HerdrAgentStatus.done:
      return '任务结束，可以接收输入';
    case HerdrAgentStatus.unknown:
      return 'Herdr 无法确认该 agent 的状态，不代表已完成';
  }
}

IconData herdrStatusIcon(HerdrAgentStatus status) {
  switch (status) {
    case HerdrAgentStatus.idle:
      return Icons.pause_circle_outline_rounded;
    case HerdrAgentStatus.working:
      return Icons.bolt_rounded;
    case HerdrAgentStatus.blocked:
      return Icons.front_hand_rounded;
    case HerdrAgentStatus.done:
      return Icons.check_circle_outline_rounded;
    case HerdrAgentStatus.unknown:
      return Icons.help_outline_rounded;
  }
}

Color herdrStatusColor(ColorScheme scheme, HerdrAgentStatus status) {
  switch (status) {
    case HerdrAgentStatus.idle:
      return scheme.secondary;
    case HerdrAgentStatus.working:
      return scheme.primary;
    case HerdrAgentStatus.blocked:
      return scheme.tertiary;
    case HerdrAgentStatus.done:
      return scheme.outline;
    case HerdrAgentStatus.unknown:
      return scheme.error;
  }
}

/// Small coloured status chip used by workspace, tab and agent rows.
class HerdrStatusChip extends StatelessWidget {
  const HerdrStatusChip({
    super.key,
    required this.status,
    this.compact = false,
  });

  final HerdrAgentStatus status;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = herdrStatusColor(scheme, status);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 6 : 8,
        vertical: compact ? 2 : 3,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(herdrStatusIcon(status), size: compact ? 11 : 13, color: color),
          const SizedBox(width: 4),
          Text(
            herdrStatusLabel(status),
            style: TextStyle(
              fontSize: compact ? 10.5 : 11.5,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

/// Monospace path line shared by Herdr rows.
///
/// Paths come from the paired PC and can be long; a middle ellipsis keeps the
/// trailing project/file name visible on narrow phone widths.
class HerdrPath extends StatelessWidget {
  const HerdrPath(
    this.path, {
    super.key,
    this.maxLines = 1,
    this.maxChars = 44,
  });

  final String path;
  final int maxLines;
  final int maxChars;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Text(
      ellipsizePath(path, max: maxChars),
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
      style: AppTheme.mono(11, color: scheme.onSurfaceVariant, height: 1.3),
    );
  }
}
