import 'package:flutter/material.dart';

import '../models/protocol.dart';
import '../theme/app_theme.dart';
import 'tool_format.dart';

/// What the user decided on a permission request.
class PermissionAnswer {
  const PermissionAnswer(this.decision, {this.message, this.answers});

  /// allow | allow_always | deny
  final String decision;
  final String? message;
  final Map<String, String>? answers;
}

/// Pinned above the composer while Claude waits for a decision.
class PermissionCard extends StatefulWidget {
  const PermissionCard({
    super.key,
    required this.request,
    required this.onAnswer,
    this.index = 1,
    this.total = 1,
  });

  final PermissionRequestEvent request;
  final Future<void> Function(PermissionAnswer answer) onAnswer;
  final int index;
  final int total;

  @override
  State<PermissionCard> createState() => _PermissionCardState();
}

class _PermissionCardState extends State<PermissionCard> {
  bool _sending = false;
  final Map<int, Set<String>> _picked = <int, Set<String>>{};
  final Map<int, TextEditingController> _other = <int, TextEditingController>{};

  @override
  void dispose() {
    for (final c in _other.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _answer(PermissionAnswer answer) async {
    setState(() => _sending = true);
    try {
      await widget.onAnswer(answer);
    } finally {
      // On success the card disappears when the resolution event arrives.
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _denyWithNote() async {
    final controller = TextEditingController();
    final note = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('拒绝并告诉 Claude'),
        content: TextField(
          controller: controller,
          autofocus: true,
          minLines: 2,
          maxLines: 5,
          decoration: const InputDecoration(
            hintText: '例如：不要删除这个目录，改用 git clean -n 先看看',
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('拒绝'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (note != null) await _answer(PermissionAnswer('deny', message: note));
  }

  // --- AskUserQuestion ------------------------------------------------------

  static const String _otherKey = '\u0000other';

  TextEditingController _otherController(int i) =>
      _other.putIfAbsent(i, () => TextEditingController());

  String? _answerFor(int i, Question q) {
    final picked = _picked[i] ?? const <String>{};
    final labels = <String>[
      for (final o in q.options)
        if (picked.contains(o.label)) o.label,
      if (picked.contains(_otherKey) && _otherController(i).text.trim().isNotEmpty)
        _otherController(i).text.trim(),
    ];
    return labels.isEmpty ? null : labels.join(', ');
  }

  bool _allAnswered(List<Question> qs) {
    for (var i = 0; i < qs.length; i++) {
      if (_answerFor(i, qs[i]) == null) return false;
    }
    return true;
  }

  void _toggle(int i, Question q, String key) {
    setState(() {
      final set = _picked.putIfAbsent(i, () => <String>{});
      if (q.multiSelect) {
        if (!set.remove(key)) set.add(key);
      } else {
        final had = set.contains(key);
        set.clear();
        if (!had) set.add(key);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final r = widget.request;
    final isPlan = r.toolName == 'ExitPlanMode';

    return Container(
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: scheme.tertiary,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  r.isQuestion ? Icons.help_outline_rounded : toolIcon(r.toolName),
                  size: 19,
                  color: scheme.onTertiary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  r.title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: scheme.onTertiaryContainer,
                  ),
                ),
              ),
              if (widget.total > 1)
                Text(
                  '${widget.index}/${widget.total}',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: scheme.onTertiaryContainer,
                  ),
                ),
            ],
          ),
          if (r.description != null && r.description!.isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              r.description!,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.4,
                color: scheme.onTertiaryContainer.withValues(alpha: 0.85),
              ),
            ),
          ],
          const SizedBox(height: 10),
          if (r.isQuestion)
            ..._questionBody(scheme, r.questions!)
          else ...<Widget>[
            ..._toolBody(scheme, r),
            const SizedBox(height: 12),
            _actions(scheme, r, isPlan),
          ],
        ],
      ),
    );
  }

  List<Widget> _toolBody(ColorScheme scheme, PermissionRequestEvent r) {
    final detail = describeToolInput(r.toolName, r.input);
    final style = AppTheme.mono(12, color: scheme.onSurface);
    return <Widget>[
      if (detail.primary != null) CodeBox(text: detail.primary!, style: style, maxHeight: 120),
      if (detail.primary != null && detail.body != null) const SizedBox(height: 6),
      if (detail.body != null)
        CodeBox(
          text: detail.body!,
          diff: detail.diff,
          style: r.toolName == 'ExitPlanMode'
              ? TextStyle(fontSize: 13.5, height: 1.5, color: scheme.onSurface)
              : style,
          maxHeight: r.toolName == 'ExitPlanMode' ? 320 : 200,
        ),
    ];
  }

  Widget _actions(ColorScheme scheme, PermissionRequestEvent r, bool isPlan) {
    final busy = _sending;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: OutlinedButton(
                onPressed: busy
                    ? null
                    : isPlan
                        ? _denyWithNote
                        : () => _answer(const PermissionAnswer('deny')),
                style: OutlinedButton.styleFrom(
                  foregroundColor: scheme.onTertiaryContainer,
                  side: BorderSide(color: scheme.onTertiaryContainer.withValues(alpha: 0.4)),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                child: Text(isPlan ? '继续规划' : '拒绝'),
              ),
            ),
            if (r.canAlwaysAllow) ...<Widget>[
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.tonal(
                  onPressed: busy ? null : () => _answer(const PermissionAnswer('allow_always')),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  child: const Text('始终允许'),
                ),
              ),
            ],
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton(
                onPressed: busy ? null : () => _answer(const PermissionAnswer('allow')),
                style: FilledButton.styleFrom(
                  backgroundColor: scheme.tertiary,
                  foregroundColor: scheme.onTertiary,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                child: busy
                    ? SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: scheme.onTertiary,
                        ),
                      )
                    : Text(isPlan ? '开始执行' : '允许'),
              ),
            ),
          ],
        ),
        if (!isPlan)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: busy ? null : _denyWithNote,
              style: TextButton.styleFrom(
                foregroundColor: scheme.onTertiaryContainer,
                visualDensity: VisualDensity.compact,
              ),
              icon: const Icon(Icons.edit_note_rounded, size: 18),
              label: const Text('拒绝并说明原因'),
            ),
          ),
      ],
    );
  }

  List<Widget> _questionBody(ColorScheme scheme, List<Question> questions) {
    final onColor = scheme.onTertiaryContainer;
    return <Widget>[
      for (var i = 0; i < questions.length; i++) ...<Widget>[
        if (i > 0) const SizedBox(height: 14),
        if (questions[i].header != null && questions[i].header!.isNotEmpty)
          Text(
            questions[i].header!,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
              color: onColor.withValues(alpha: 0.75),
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 2, bottom: 8),
          child: Text(
            questions[i].question + (questions[i].multiSelect ? '（可多选）' : ''),
            style: TextStyle(fontSize: 14, height: 1.4, color: onColor),
          ),
        ),
        for (final option in questions[i].options)
          _OptionTile(
            label: option.label,
            description: option.description,
            selected: _picked[i]?.contains(option.label) ?? false,
            multi: questions[i].multiSelect,
            onTap: _sending ? null : () => _toggle(i, questions[i], option.label),
          ),
        _OptionTile(
          label: '其他',
          selected: _picked[i]?.contains(_otherKey) ?? false,
          multi: questions[i].multiSelect,
          onTap: _sending ? null : () => _toggle(i, questions[i], _otherKey),
        ),
        if (_picked[i]?.contains(_otherKey) ?? false)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: TextField(
              controller: _otherController(i),
              autofocus: true,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: '输入你的回答',
                fillColor: scheme.surface,
                isDense: true,
              ),
            ),
          ),
      ],
      const SizedBox(height: 12),
      Row(
        children: <Widget>[
          TextButton(
            onPressed: _sending ? null : () => _answer(const PermissionAnswer('deny', message: 'The user declined to answer.')),
            style: TextButton.styleFrom(foregroundColor: onColor),
            child: const Text('不回答'),
          ),
          const Spacer(),
          FilledButton.icon(
            onPressed: _sending || !_allAnswered(questions)
                ? null
                : () => _answer(PermissionAnswer('allow', answers: <String, String>{
                      for (var i = 0; i < questions.length; i++)
                        questions[i].question: _answerFor(i, questions[i])!,
                    })),
            style: FilledButton.styleFrom(
              backgroundColor: scheme.tertiary,
              foregroundColor: scheme.onTertiary,
            ),
            icon: const Icon(Icons.send_rounded, size: 18),
            label: const Text('提交回答'),
          ),
        ],
      ),
    ];
  }
}

class _OptionTile extends StatelessWidget {
  const _OptionTile({
    required this.label,
    required this.selected,
    required this.multi,
    required this.onTap,
    this.description,
  });

  final String label;
  final String? description;
  final bool selected;
  final bool multi;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final icon = multi
        ? (selected ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded)
        : (selected ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: selected ? scheme.surface : scheme.surface.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: <Widget>[
                Icon(icon, size: 20, color: selected ? scheme.tertiary : scheme.outline),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
                      if (description != null && description!.isNotEmpty)
                        Text(
                          description!,
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.35,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
