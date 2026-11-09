import 'package:flutter/material.dart';

import '../models/tool.dart';
import '../state/assistant_controller.dart';
import '../widgets/common.dart';
import 'home_shell.dart';

/// At-a-glance状态：relay, phone pairing, and each tool's discovery result.
class OverviewPage extends StatelessWidget {
  const OverviewPage({super.key, required this.controller});

  final AssistantController controller;

  @override
  Widget build(BuildContext context) {
    if (controller.starting) {
      return const PageScaffold(
        title: '总览',
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (controller.fatalError != null) {
      return PageScaffold(
        title: '总览',
        child: MessageState(
          icon: Icons.error_outline_rounded,
          title: '无法启动后台服务',
          body: controller.fatalError!,
          action: FilledButton.icon(
            onPressed: () => controller.start(),
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('重试'),
          ),
        ),
      );
    }
    final snapshot = controller.snapshot;
    return PageScaffold(
      title: '总览',
      subtitle: snapshot.relayUrl ?? '未配置中继地址',
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          SectionCard(
            title: '连接状态',
            trailing: StatusPill(
              label: relayStatusText(controller),
              tone: snapshot.relayOnline
                  ? StatusTone.online
                  : snapshot.retries > 0
                  ? StatusTone.warning
                  : StatusTone.neutral,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _row(context, '中继地址', snapshot.relayUrl ?? '未设置'),
                _row(
                  context,
                  '手机配对',
                  snapshot.pairedClients > 0
                      ? '已配对 ${snapshot.pairedClients} 台'
                      : '尚未配对',
                ),
                if (snapshot.lastError != null)
                  _row(context, '最近错误', snapshot.lastError!),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: '工具发现',
            subtitle: '本机实际安装情况；未安装的工具不能绑定',
            trailing: IconButton(
              tooltip: '重新检测',
              onPressed: controller.refreshTools,
              icon: const Icon(Icons.refresh_rounded),
            ),
            child: Column(
              children: <Widget>[
                for (final kind in ToolKind.values)
                  _toolRow(context, snapshot.probe(kind), kind),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: ListTile(
              leading: const Icon(Icons.qr_code_2_rounded),
              title: const Text('配对手机'),
              subtitle: const Text('显示二维码或短码，手机扫一次即可连接'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => DefaultTabController.maybeOf(context),
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: 96,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12.5,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          child: SelectableText(
            value,
            style: const TextStyle(fontSize: 13),
          ),
        ),
      ],
    ),
  );

  Widget _toolRow(BuildContext context, ToolProbe? probe, ToolKind kind) {
    final installed = probe?.installed ?? false;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        installed ? Icons.check_circle_rounded : Icons.remove_circle_outline,
        color: installed
            ? const Color(0xFF15803D)
            : Theme.of(context).colorScheme.outline,
      ),
      title: Text(kind.label),
      subtitle: Text(probe?.reason ?? probe?.statusLabel ?? '未检测'),
      trailing: probe?.installed == true
          ? StatusPill(
              label: probe!.statusLabel,
              tone: probe.loggedIn == false
                  ? StatusTone.warning
                  : StatusTone.online,
            )
          : const StatusPill(label: '未安装', tone: StatusTone.neutral),
    );
  }
}
