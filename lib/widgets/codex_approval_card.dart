import 'package:flutter/material.dart';

import '../models/protocol.dart';
import '../state/remote_controller.dart';

class CodexApprovalCard extends StatefulWidget {
  const CodexApprovalCard({
    super.key,
    required this.request,
    required this.total,
    required this.enabled,
    required this.onRespond,
  });
  final CodexPendingRequest request;
  final int total;
  final bool enabled;
  final Future<void> Function(
    String decision,
    Map<String, List<String>>? answers,
  )
  onRespond;

  @override
  State<CodexApprovalCard> createState() => _CodexApprovalCardState();
}

class _CodexApprovalCardState extends State<CodexApprovalCard> {
  final Map<String, String> _answers = <String, String>{};
  bool _busy = false;
  bool _answered = false;
  String? _error;

  Future<void> _respond(String decision) async {
    if (_busy || _answered || !widget.enabled) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onRespond(
        decision,
        decision == 'accept' && widget.request.kind == 'userInput'
            ? <String, List<String>>{
                for (final entry in _answers.entries)
                  entry.key: <String>[entry.value],
              }
            : null,
      );
      if (mounted) setState(() => _answered = true);
    } on RemoteException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final request = widget.request;
    final enabled = widget.enabled && !_busy && !_answered;
    final complete = request.questions.every(
      (q) => (_answers[q.id]?.trim() ?? '').isNotEmpty,
    );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(request.title, style: Theme.of(context).textTheme.titleMedium),
            if (widget.total > 1) Text('${widget.total} 个请求待处理'),
            if (request.description?.isNotEmpty == true)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: SelectableText(request.description!),
              ),
            if (!request.canAccept)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('此请求需要在电脑上处理，也可以在这里拒绝或取消。'),
              ),
            for (final question in request.questions) ...<Widget>[
              const SizedBox(height: 12),
              Text(question.question),
              RadioGroup<String>(
                groupValue: _answers[question.id],
                onChanged: (value) =>
                    setState(() => _answers[question.id] = value!),
                child: Column(
                  children: <Widget>[
                    for (final option in question.options)
                      RadioListTile<String>(
                        title: Text(option.label),
                        subtitle: option.description == null
                            ? null
                            : Text(option.description!),
                        value: option.label,
                        enabled: enabled && request.canAccept,
                      ),
                  ],
                ),
              ),
              if (question.options.isEmpty || question.isOther)
                TextField(
                  key: ValueKey<String>('codex-answer-${question.id}'),
                  enabled: enabled && request.canAccept,
                  obscureText: question.isSecret,
                  decoration: const InputDecoration(labelText: '你的回答'),
                  onChanged: (value) =>
                      setState(() => _answers[question.id] = value),
                ),
            ],
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (_answered) const Text('已提交，等待电脑更新'),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                if (request.canAccept)
                  FilledButton(
                    onPressed: enabled && complete
                        ? () => _respond('accept')
                        : null,
                    child: Text(request.kind == 'userInput' ? '提交回答' : '允许'),
                  ),
                OutlinedButton(
                  onPressed: enabled ? () => _respond('decline') : null,
                  child: const Text('拒绝'),
                ),
                TextButton(
                  onPressed: enabled ? () => _respond('cancel') : null,
                  child: const Text('取消请求'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
