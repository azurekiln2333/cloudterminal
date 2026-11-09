import 'package:flutter/material.dart';

import '../models/protocol.dart';
import '../state/codex_thread_view.dart';
import '../state/remote_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/codex_approval_card.dart';
import '../widgets/event_tiles.dart';

class CodexScreen extends StatefulWidget {
  const CodexScreen({
    super.key,
    required this.controller,
    required this.thread,
    this.navigationButton,
  });
  final RemoteController controller;
  final CodexThread thread;
  final Widget? navigationButton;

  @override
  State<CodexScreen> createState() => _CodexScreenState();
}

class _CodexScreenState extends State<CodexScreen> {
  late final CodexThreadView _view = CodexThreadView(
    widget.controller,
    widget.thread,
  );
  final TextEditingController _input = TextEditingController();
  bool _acting = false;
  String? _actionError;

  @override
  void dispose() {
    _view.dispose();
    _input.dispose();
    super.dispose();
  }

  Future<void> _act(Future<void> Function() action) async {
    if (_acting) return;
    setState(() {
      _acting = true;
      _actionError = null;
    });
    try {
      await action();
      await _view.load(refresh: true);
    } on RemoteException catch (e) {
      if (mounted) setState(() => _actionError = e.message);
    } finally {
      if (mounted) setState(() => _acting = false);
    }
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || !_view.canSend) return;
    await _act(() async {
      await widget.controller.codexSend(
        _view.thread.id,
        text,
        turnId: _view.thread.activeTurnId,
      );
      if (mounted) _input.clear();
    });
  }

  String? get _readOnlyReason {
    final c = widget.controller;
    if (!c.isOnline) return '电脑离线，当前显示已读取的历史';
    if (c.agent?.codex?.available != true) {
      return c.agent?.codex?.reason ?? 'Codex Desktop 暂不可用';
    }
    if (c.agent?.codex?.canControl != true) {
      return c.agent?.codex?.reason ?? '只读历史：当前电脑端未启用远程控制';
    }
    if (!_view.loaded) return '正在读取会话状态…';
    if (_view.error != null) return '读取失败，请刷新会话后继续';
    if (!_view.thread.canAcceptDirectInput) {
      return _view.canResume ? '历史会话，恢复后可继续输入' : '只读历史：此会话暂不接受直接输入';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge(<Listenable>[_view, widget.controller]),
    builder: (context, _) {
      final scheme = Theme.of(context).colorScheme;
      final thread = _view.thread;
      final reason = _readOnlyReason;
      final items = <CodexItem>[for (final turn in _view.turns) ...turn.items];
      final pending = _view.pendingRequests;
      return Scaffold(
        appBar: AppBar(
          leading: widget.navigationButton,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(thread.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              Text(
                'Codex Desktop · ${thread.cwd}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ),
          actions: <Widget>[
            IconButton(
              tooltip: '刷新 Codex 会话',
              onPressed: widget.controller.isOnline && !_view.loading
                  ? () => _view.load(refresh: true)
                  : null,
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        body: Column(
          children: <Widget>[
            if (reason != null)
              Material(
                color: scheme.secondaryContainer,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: Row(
                    children: <Widget>[
                      const Icon(Icons.info_outline, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          reason,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                      if (_view.canResume)
                        TextButton(
                          onPressed: _acting
                              ? null
                              : () => _act(
                                  () =>
                                      widget.controller.codexResume(thread.id),
                                ),
                          child: const Text('恢复会话'),
                        ),
                    ],
                  ),
                ),
              ),
            if (_view.loading) const LinearProgressIndicator(minHeight: 2),
            if (_actionError != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  _actionError!,
                  style: TextStyle(color: scheme.error),
                ),
              ),
            if (_view.error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        _view.error!,
                        style: TextStyle(color: scheme.error),
                      ),
                    ),
                    TextButton(
                      onPressed: widget.controller.isOnline && !_view.loading
                          ? () => _view.load(refresh: true)
                          : null,
                      child: const Text('重试'),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: !_view.loaded && _view.loading
                  ? const Center(child: CircularProgressIndicator())
                  : items.isEmpty && _view.nextCursor == null
                  ? const Center(child: Text('没有可显示的历史记录'))
                  : ListView.builder(
                      key: ValueKey<String>('codex-transcript-${thread.id}'),
                      reverse: true,
                      padding: const EdgeInsets.all(16),
                      itemCount:
                          items.length + (_view.nextCursor == null ? 0 : 1),
                      itemBuilder: (context, index) {
                        if (index == items.length) {
                          return TextButton(
                            onPressed:
                                _view.loading || !widget.controller.isOnline
                                ? null
                                : () => _view.load(),
                            child: const Text('加载更早记录'),
                          );
                        }
                        final item = items[items.length - index - 1];
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: _CodexItemTile(item: item),
                        );
                      },
                    ),
            ),
            if (pending.isNotEmpty)
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * .45,
                ),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(12),
                  child: CodexApprovalCard(
                    key: ValueKey<String>(pending.first.requestId),
                    request: pending.first,
                    total: pending.length,
                    enabled: _view.canControl,
                    onRespond: (decision, answers) async {
                      await widget.controller.codexRespond(
                        thread.id,
                        pending.first.requestId,
                        decision,
                        answers: answers,
                      );
                      await _view.load(refresh: true);
                    },
                  ),
                ),
              ),
            if (_view.canSend)
              Material(
                color: scheme.surfaceContainer,
                child: SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: <Widget>[
                        Expanded(
                          child: TextField(
                            controller: _input,
                            enabled: !_acting,
                            minLines: 1,
                            maxLines: 6,
                            decoration: InputDecoration(
                              hintText: thread.activeTurnId == null
                                  ? '继续这个 Codex 会话…'
                                  : '补充当前任务…',
                            ),
                          ),
                        ),
                        if (thread.activeTurnId != null)
                          IconButton.filledTonal(
                            tooltip: '停止 Codex',
                            onPressed: _acting
                                ? null
                                : () => _act(
                                    () => widget.controller.codexInterrupt(
                                      thread.id,
                                      thread.activeTurnId!,
                                    ),
                                  ),
                            icon: const Icon(Icons.stop_rounded),
                          ),
                        const SizedBox(width: 8),
                        ValueListenableBuilder<TextEditingValue>(
                          valueListenable: _input,
                          builder: (context, value, _) => IconButton.filled(
                            tooltip: '发送给 Codex',
                            onPressed: _acting || value.text.trim().isEmpty
                                ? null
                                : _send,
                            icon: const Icon(Icons.arrow_upward_rounded),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
    },
  );
}

class _CodexItemTile extends StatelessWidget {
  const _CodexItemTile({required this.item});
  final CodexItem item;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (item.kind == 'assistant') return AssistantText(text: item.text);
    if (item.kind == 'user') {
      return Align(
        alignment: Alignment.centerRight,
        child: Card(
          color: scheme.primaryContainer,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: SelectableText(
              item.text,
              style: TextStyle(color: scheme.onPrimaryContainer),
            ),
          ),
        ),
      );
    }
    final label = switch (item.kind) {
      'thinking' => '思考过程',
      'tool' => item.toolName ?? '工具',
      'error' => '错误',
      'system' => '会话信息',
      _ => '其他记录',
    };
    return Card(
      child: ExpansionTile(
        title: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color: item.kind == 'error'
                ? scheme.error
                : scheme.onSurfaceVariant,
          ),
        ),
        initiallyExpanded: item.kind == 'error',
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SelectableText(
              item.text.isEmpty ? '此记录没有文本内容' : item.text,
              style: item.kind == 'tool' ? AppTheme.mono(12) : null,
            ),
          ),
        ],
      ),
    );
  }
}
