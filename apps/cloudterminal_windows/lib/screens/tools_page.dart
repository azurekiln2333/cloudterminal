import 'package:flutter/material.dart';

import '../models/tool.dart';
import '../state/assistant_controller.dart';
import '../widgets/common.dart';
import 'home_shell.dart';

/// 每个工具的发现结果、能力说明与绑定入口。
///
/// 这里如实说明每个工具支持哪种接入方式，避免用户误以为"任意已运行进程
/// 都能被读取"。真实能力见 design.md 与 research/tool-sessions-*.md。
class ToolsPage extends StatelessWidget {
  const ToolsPage({super.key, required this.controller});

  final AssistantController controller;

  @override
  Widget build(BuildContext context) => PageScaffold(
    title: '工具',
    subtitle: '发现、能力与绑定',
    actions: <Widget>[
      IconButton(
        tooltip: '重新检测',
        onPressed: controller.refreshTools,
        icon: const Icon(Icons.refresh_rounded),
      ),
    ],
    child: ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        for (final kind in ToolKind.values)
          _ToolCard(
            kind: kind,
            probe: controller.snapshot.probe(kind),
            bindings: controller.snapshot.bindings
                .where((b) => b.kind == kind)
                .toList(),
            controller: controller,
          ),
      ],
    ),
  );
}

class _ToolCard extends StatelessWidget {
  const _ToolCard({
    required this.kind,
    required this.probe,
    required this.bindings,
    required this.controller,
  });

  final ToolKind kind;
  final ToolProbe? probe;
  final List<SessionBinding> bindings;
  final AssistantController controller;

  @override
  Widget build(BuildContext context) {
    final installed = probe?.installed ?? false;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: SectionCard(
        title: kind.label,
        subtitle: kind.description,
        trailing: installed
            ? StatusPill(
                label: probe!.statusLabel,
                tone: probe!.loggedIn == false
                    ? StatusTone.warning
                    : StatusTone.online,
              )
            : const StatusPill(label: '未安装', tone: StatusTone.neutral),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _capabilities(context),
            if (!installed) ...<Widget>[
              const SizedBox(height: 12),
              _installHint(context),
            ] else if (bindings.isEmpty) ...<Widget>[
              const SizedBox(height: 12),
              Text(
                '可以在「会话」页选择一个会话进行绑定。',
                style: TextStyle(
                  fontSize: 12.5,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ] else ...<Widget>[
              const SizedBox(height: 12),
              for (final binding in bindings)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: const Icon(Icons.link_rounded),
                  title: Text(binding.title),
                  subtitle: Text(binding.originLabel),
                  trailing: IconButton(
                    tooltip: '解除绑定',
                    onPressed: () => controller.unbind(binding),
                    icon: const Icon(Icons.link_off_rounded, size: 18),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _capabilities(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final rows = switch (kind) {
      ToolKind.herdr => const <(String, String, bool)>[
        ('管理型', '工作区/面板控制（经中继转发）', true),
        ('只读', 'pane read 屏幕内容，轮询刷新', false),
        ('不支持', '读取任意已运行 TUI 进程的 stdout', false),
      ],
      ToolKind.codex => const <(String, String, bool)>[
        ('管理型', 'app-server JSON-RPC，实时事件流', true),
        ('只读', 'ThreadList / ThreadRead 历史', false),
        ('不支持', '接管已在别人终端里的 TUI 会话', false),
      ],
      ToolKind.claude => const <(String, String, bool)>[
        ('管理型', '--output-format stream-json 实时流', true),
        ('只读', 'claude agents --json + logs 快照', false),
        ('不支持', '读取交互式 TUI 会话的 stdout', false),
      ],
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (final (tag, text, live) in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Container(
                  margin: const EdgeInsets.only(top: 2),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: (live
                            ? const Color(0xFF15803D)
                            : scheme.onSurfaceVariant)
                        .withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Text(
                    tag,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: live
                          ? const Color(0xFF15803D)
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(text, style: const TextStyle(fontSize: 12.5)),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _installHint(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Text(
      switch (kind) {
        ToolKind.herdr => '安装 Herdr 并在电脑上启动一次；重启本助手后即可看到工作区。',
        ToolKind.codex => '安装 Codex CLI（npm i -g @openai/codex 或官方安装包）后重新检测。',
        ToolKind.claude => '安装 Claude Code 并登录（claude login）后重新检测。',
      },
      style: const TextStyle(fontSize: 12.5, height: 1.5),
    ),
  );
}
