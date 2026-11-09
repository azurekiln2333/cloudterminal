import 'package:flutter/material.dart';

import '../models/protocol.dart';
import '../state/session_view.dart';
import '../theme/app_theme.dart';
import '../util/format.dart';
import 'tool_format.dart';

/// Whether [e] gets its own row in the transcript. Tool results render
/// inside their tool call; resolutions update the request row; pending
/// requests live in the permission dock instead.
bool isListed(SessionEvent e, SessionView view) {
  switch (e) {
    case ToolResultEvent():
      return false;
    case PermissionResolvedEvent():
      return false;
    case PermissionRequestEvent():
      return view.resolutionFor(e.requestId) != null;
    case TerminalOutputEvent():
    case UnknownEvent():
      return false;
    default:
      return true;
  }
}

class EventTile extends StatelessWidget {
  const EventTile({super.key, required this.event, required this.view});

  final SessionEvent event;
  final SessionView view;

  @override
  Widget build(BuildContext context) {
    final e = event;
    return switch (e) {
      UserEvent() => _UserBubble(text: e.text),
      AssistantEvent() => AssistantText(text: e.text),
      ThinkingEvent() => _Thinking(text: e.text),
      ToolUseEvent() => _ToolCall(
        event: e,
        result: view.resultFor(e.toolUseId),
        running: view.info.isBusy,
      ),
      PermissionRequestEvent() => _Decision(
        request: e,
        decision: view.resolutionFor(e.requestId)?.decision,
      ),
      ResultEvent() => _Result(event: e),
      SystemEvent() => _Notice(text: e.text),
      ErrorEvent() => _ErrorRow(text: e.text),
      TerminalOutputEvent() ||
      ToolResultEvent() ||
      PermissionResolvedEvent() ||
      UnknownEvent() => const SizedBox.shrink(),
    };
  }
}

class _UserBubble extends StatelessWidget {
  const _UserBubble({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.82,
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: scheme.primaryContainer,
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(18),
              topRight: Radius.circular(18),
              bottomLeft: Radius.circular(18),
              bottomRight: Radius.circular(6),
            ),
          ),
          child: SelectableText(
            text,
            style: TextStyle(color: scheme.onPrimaryContainer, height: 1.45),
          ),
        ),
      ),
    );
  }
}

/// Assistant prose with ``` fenced blocks rendered as code.
class AssistantText extends StatelessWidget {
  const AssistantText({super.key, required this.text, this.streaming = false});

  final String text;
  final bool streaming;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final parts = _splitFences(text);
    final prose = TextStyle(
      color: scheme.onSurface,
      height: 1.55,
      fontSize: 14.5,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (final (isCode, chunk) in parts)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: isCode
                ? CodeBox(
                    text: chunk,
                    maxHeight: 320,
                    style: AppTheme.mono(12.5, color: scheme.onSurface),
                  )
                : SelectableText(chunk, style: prose),
          ),
        if (streaming)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Container(
              width: 8,
              height: 16,
              color: scheme.primary.withValues(alpha: 0.7),
            ),
          ),
      ],
    );
  }
}

List<(bool, String)> _splitFences(String text) {
  final out = <(bool, String)>[];
  final fence = RegExp(r'```[^\n]*\n([\s\S]*?)(```|$)');
  var last = 0;
  for (final m in fence.allMatches(text)) {
    final before = text.substring(last, m.start).trim();
    if (before.isNotEmpty) out.add((false, before));
    out.add((true, m.group(1)!.trimRight()));
    last = m.end;
  }
  final rest = text.substring(last).trim();
  if (rest.isNotEmpty) out.add((false, rest));
  return out.isEmpty ? <(bool, String)>[(false, text)] : out;
}

class _Thinking extends StatefulWidget {
  const _Thinking({required this.text});

  final String text;

  @override
  State<_Thinking> createState() => _ThinkingState();
}

class _ThinkingState extends State<_Thinking> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = scheme.onSurfaceVariant;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => setState(() => _open = !_open),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.psychology_alt_outlined, size: 16, color: muted),
                const SizedBox(width: 6),
                Text('思考', style: TextStyle(fontSize: 12.5, color: muted)),
                Icon(
                  _open ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                  size: 18,
                  color: muted,
                ),
              ],
            ),
            if (_open)
              Padding(
                padding: const EdgeInsets.only(left: 22, top: 4),
                child: SelectableText(
                  widget.text,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.5,
                    fontStyle: FontStyle.italic,
                    color: muted,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ToolCall extends StatefulWidget {
  const _ToolCall({
    required this.event,
    required this.result,
    required this.running,
  });

  final ToolUseEvent event;
  final ToolResultEvent? result;
  final bool running;

  @override
  State<_ToolCall> createState() => _ToolCallState();
}

class _ToolCallState extends State<_ToolCall> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final e = widget.event;
    final result = widget.result;
    final failed = result?.isError ?? false;
    final detail = describeToolInput(e.name, e.input);

    final Widget status;
    if (result == null) {
      status = widget.running
          ? SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: scheme.primary,
              ),
            )
          : Icon(Icons.more_horiz_rounded, size: 16, color: scheme.outline);
    } else {
      status = Icon(
        failed ? Icons.error_rounded : Icons.check_circle_rounded,
        size: 16,
        color: failed ? scheme.error : scheme.primary,
      );
    }

    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => setState(() => _open = !_open),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(toolIcon(e.name), size: 17, color: scheme.secondary),
                  const SizedBox(width: 8),
                  Text(
                    toolLabel(e.name),
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      e.summary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTheme.mono(
                        12,
                        color: scheme.onSurfaceVariant,
                        height: 1.3,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  status,
                ],
              ),
              if (_open) ...<Widget>[
                if (detail.primary != null) ...<Widget>[
                  const SizedBox(height: 10),
                  CodeBox(
                    text: detail.primary!,
                    style: AppTheme.mono(12, color: scheme.onSurface),
                  ),
                ],
                if (detail.body != null) ...<Widget>[
                  const SizedBox(height: 6),
                  CodeBox(
                    text: detail.body!,
                    diff: detail.diff,
                    style: AppTheme.mono(12, color: scheme.onSurface),
                  ),
                ],
                if (result != null && result.content.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 10),
                  Text(
                    failed ? '错误输出' : '输出',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: failed ? scheme.error : scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 4),
                  CodeBox(
                    text: result.content,
                    maxHeight: 280,
                    style: AppTheme.mono(
                      11.5,
                      color: failed ? scheme.error : scheme.onSurface,
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Decision extends StatelessWidget {
  const _Decision({required this.request, required this.decision});

  final PermissionRequestEvent request;
  final String? decision;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, label, color) = switch (decision) {
      'allow' => (Icons.verified_user_outlined, '已允许', scheme.primary),
      'allow_always' => (Icons.verified_user_rounded, '已始终允许', scheme.primary),
      _ => (Icons.block_rounded, '已拒绝', scheme.error),
    };
    final what = request.isQuestion ? '已回答问题' : label;
    return Row(
      children: <Widget>[
        Icon(
          request.isQuestion ? Icons.question_answer_outlined : icon,
          size: 15,
          color: color,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            '$what · ${request.title}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}

class _Result extends StatelessWidget {
  const _Result({required this.event});

  final ResultEvent event;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = event.isError ? scheme.error : scheme.primary;
    final parts = <String>[
      event.isError ? '任务出错' : '本轮完成',
      if (event.turns > 0) '${event.turns} 轮',
      if (event.duration > Duration.zero) formatDuration(event.duration),
      if (event.costUsd > 0) '累计 ${formatCost(event.costUsd)}',
    ];
    return Column(
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(child: Divider(color: color.withValues(alpha: 0.3))),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(
                    event.isError
                        ? Icons.error_outline_rounded
                        : Icons.task_alt_rounded,
                    size: 15,
                    color: color,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    parts.join(' · '),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: color,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(child: Divider(color: color.withValues(alpha: 0.3))),
          ],
        ),
        if (event.isError && event.text.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              event.text,
              style: TextStyle(fontSize: 12.5, color: scheme.error),
            ),
          ),
      ],
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 11.5, color: scheme.outline, height: 1.4),
      ),
    );
  }
}

class _ErrorRow extends StatelessWidget {
  const _ErrorRow({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            Icons.error_outline_rounded,
            size: 18,
            color: scheme.onErrorContainer,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SelectableText(
              text,
              style: TextStyle(color: scheme.onErrorContainer, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}
