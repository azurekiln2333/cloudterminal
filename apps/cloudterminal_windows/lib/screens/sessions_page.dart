import 'package:flutter/material.dart';

import '../models/tool.dart';
import '../state/assistant_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';
import 'home_shell.dart';

/// 会话列表 + 输出视图。
///
/// 左侧列出可绑定的会话（按工具分组），右侧显示输出。输出的来源标签始终
/// 可见：实时流 / 只读历史 / 轮询 Ns——绝不把轮询当成实时流。
class SessionsPage extends StatefulWidget {
  const SessionsPage({super.key, required this.controller});

  final AssistantController controller;

  @override
  State<SessionsPage> createState() => _SessionsPageState();
}

class _SessionsPageState extends State<SessionsPage> {
  final ScrollController _scroll = ScrollController();
  String? _selectedId;
  bool _autoScroll = true;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  SessionBinding? get _selected {
    final bindings = widget.controller.snapshot.bindings;
    for (final b in bindings) {
      if (b.id == _selectedId) return b;
    }
    return bindings.isEmpty ? null : bindings.first;
  }

  Future<void> _startManaged(BuildContext context) async {
    final prompt = await showDialog<String>(
      context: context,
      builder: (context) => const _PromptDialog(),
    );
    if (prompt == null) return;
    widget.controller.startManagedClaude(prompt: prompt.isEmpty ? null : prompt);
  }

  @override
  Widget build(BuildContext context) {
    final bindings = widget.controller.snapshot.bindings;
    if (bindings.isEmpty) {
      return PageScaffold(
        title: '会话',
        child: MessageState(
          icon: Icons.forum_outlined,
          title: '还没有可绑定的会话',
          body: '先在「工具」页确认工具已安装。管理型会话可由这里启动；'
              '已存在的会话以「只读历史」或「轮询」方式列出。',
          action: FilledButton.icon(
            onPressed: widget.controller.refreshTools,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('重新检测工具'),
          ),
        ),
      );
    }
    final selected = _selected;
    if (selected != null && _selectedId == null) {
      _selectedId = selected.id;
    }
    return PageScaffold(
      title: '会话',
      subtitle: '${bindings.length} 个可绑定会话',
      actions: <Widget>[
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: FilledButton.tonalIcon(
            onPressed: widget.controller.running
                ? () => _startManaged(context)
                : null,
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const Text('启动 Claude 托管会话'),
          ),
        ),
      ],
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 320,
            child: ListView(
              padding: const EdgeInsets.all(12),
              children: <Widget>[
                for (final kind in ToolKind.values)
                  ..._group(context, kind, bindings),
              ],
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(child: selected == null
              ? const SizedBox.shrink()
              : _outputPane(context, selected)),
        ],
      ),
    );
  }

  List<Widget> _group(
    BuildContext context,
    ToolKind kind,
    List<SessionBinding> bindings,
  ) {
    final items = bindings.where((b) => b.kind == kind).toList();
    if (items.isEmpty) return const <Widget>[];
    return <Widget>[
      Padding(
        padding: const EdgeInsets.fromLTRB(8, 12, 8, 6),
        child: Text(
          kind.label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
      for (final binding in items)
        Card(
          margin: const EdgeInsets.only(bottom: 6),
          color: binding.id == _selected?.id
              ? Theme.of(context).colorScheme.secondaryContainer
              : null,
          child: ListTile(
            dense: true,
            selected: binding.id == _selected?.id,
            title: Text(
              binding.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Row(
              children: <Widget>[
                OriginBadge(binding: binding),
                if (binding.cwd != null) ...<Widget>[
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      binding.cwd!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTheme.mono(11),
                    ),
                  ),
                ],
              ],
            ),
            onTap: () => setState(() {
              _selectedId = binding.id;
              widget.controller.bind(binding);
            }),
          ),
        ),
    ];
  }

  Widget _outputPane(BuildContext context, SessionBinding binding) {
    final events = widget.controller.events(binding.id);
    final scheme = Theme.of(context).colorScheme;    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Flexible(
                          child: Text(
                            binding.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        OriginBadge(binding: binding),
                      ],
                    ),
                    if (binding.subtitle != null || binding.cwd != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          binding.subtitle ?? binding.cwd!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              FilterChip(
                avatar: Icon(
                  Icons.vertical_align_bottom_rounded,
                  size: 16,
                  color: _autoScroll ? scheme.primary : scheme.outline,
                ),
                label: const Text('自动滚动'),
                selected: _autoScroll,
                onSelected: (v) => setState(() => _autoScroll = v),
              ),
            ],
          ),
        ),
        Expanded(
          child: events.isEmpty
              ? Center(
                  child: Text(
                    binding.origin.isLive
                        ? '尚未收到输出。'
                        : '只读历史/轮询源：点击下方刷新读取。',
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                )
              : Scrollbar(
                  controller: _scroll,
                  child: ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                    itemCount: events.length,
                    itemBuilder: (context, i) =>
                        _eventLine(context, events[i]),
                  ),
                ),
        ),
        if (binding.canAcceptInput) _inputBar(context, binding),
      ],
    );
  }

  Widget _eventLine(BuildContext context, ToolEvent event) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: SelectableText(
        event.text,
        style: AppTheme.mono(
          12.5,
          color: event.kindLabel == 'stderr' ? scheme.error : scheme.onSurface,
        ),
      ),
    );
  }

  Widget _inputBar(BuildContext context, SessionBinding binding) {
    final input = TextEditingController();
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainer,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Row(
        children: <Widget>[
          Expanded(
            child: TextField(
              controller: input,
              minLines: 1,
              maxLines: 4,
              decoration: const InputDecoration(hintText: '向该会话发送输入…'),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: () {
              final text = input.text;
              if (text.isEmpty) return;
              widget.controller.sendInput(binding.id, text);
              input.clear();
            },
            icon: const Icon(Icons.send_rounded, size: 18),
            label: const Text('发送'),
          ),
        ],
      ),
    );
  }
}

/// A single-line dialog asking for the first prompt of a managed session.
class _PromptDialog extends StatefulWidget {
  const _PromptDialog();

  @override
  State<_PromptDialog> createState() => _PromptDialogState();
}

class _PromptDialogState extends State<_PromptDialog> {
  final TextEditingController _input = TextEditingController();

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('启动 Claude 托管会话'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Text(
          '这会新建一个 Claude Code 会话并以实时流显示输出。'
          '不会附加到或重启你已有的会话。',
          style: TextStyle(fontSize: 12.5),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _input,
          autofocus: true,
          minLines: 1,
          maxLines: 4,
          decoration: const InputDecoration(hintText: '首条指令（可留空）'),
        ),
      ],
    ),
    actions: <Widget>[
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () => Navigator.of(context).pop(_input.text.trim()),
        child: const Text('启动'),
      ),
    ],
  );
}
