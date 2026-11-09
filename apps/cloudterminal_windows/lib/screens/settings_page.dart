import 'package:flutter/material.dart';

import '../state/assistant_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';
import 'home_shell.dart';

/// 设置：主题、配对身份管理、诊断信息。
class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.controller,
    required this.onSeedChanged,
    required this.onModeChanged,
  });

  final AssistantController controller;
  final ValueChanged<Color> onSeedChanged;
  final ValueChanged<ThemeMode> onModeChanged;

  @override
  Widget build(BuildContext context) {
    final snapshot = controller.snapshot;
    return SettingsScope(
      controller: controller,
      child: PageScaffold(
        title: '设置',
        child: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          const _RelaySection(),
          const SizedBox(height: 12),
          SectionCard(
            title: '外观',
            subtitle: '标准 Material 3，跟随系统明暗',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Wrap(
                  spacing: 8,
                  children: <Widget>[
                    for (final (name, color) in AppTheme.seeds)
                      FilterChip(
                        avatar: CircleAvatar(
                          radius: 8,
                          backgroundColor: color,
                        ),
                        label: Text(name),
                        selected: false,
                        onSelected: (_) => onSeedChanged(color),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                SegmentedButton<ThemeMode>(
                  segments: const <ButtonSegment<ThemeMode>>[
                    ButtonSegment(value: ThemeMode.system, label: Text('跟随系统')),
                    ButtonSegment(value: ThemeMode.light, label: Text('浅色')),
                    ButtonSegment(value: ThemeMode.dark, label: Text('深色')),
                  ],
                  selected: <ThemeMode>{controller.snapshot.relayOnline
                      ? ThemeMode.system
                      : ThemeMode.system},
                  onSelectionChanged: (s) => onModeChanged(s.first),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: '诊断',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _kv(context, '中继地址', snapshot.relayUrl ?? '未设置'),
                _kv(
                  context,
                  '中继状态',
                  relayStatusText(controller),
                ),
                _kv(context, '已配对手机', '${snapshot.pairedClients} 台'),
                _kv(
                  context,
                  '本地服务端口',
                  snapshot.statusPort?.toString() ?? '未知',
                ),
                if (snapshot.lastError != null)
                  _kv(context, '最近错误', snapshot.lastError!),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: '配对身份',
            subtitle: '重置后，所有已配对的手机都需要重新配对',
            child: Row(
              children: <Widget>[
                FilledButton.tonalIcon(
                  onPressed: () => _confirmReset(context),
                  icon: const Icon(Icons.key_off_rounded, size: 18),
                  label: const Text('重置配对身份'),
                ),
              ],
            ),
          ),
        ],
        ),
      ),
    );
  }

  Widget _kv(BuildContext context, String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: 110,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12.5,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(child: SelectableText(value, style: const TextStyle(fontSize: 13))),
      ],
    ),
  );

  Future<void> _confirmReset(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.warning_amber_rounded),
        title: const Text('重置配对身份？'),
        content: const Text('这会生成新的设备身份与密钥，所有已配对的手机都会断开，需要重新配对。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('确认重置'),
          ),
        ],
      ),
    );
    if (ok == true) await controller.resetPairing();
  }
}

/// First-run relay configuration. Most users never touch this: if the build
/// ships a `bootstrap.json` the address is already set. It exists so someone
/// with a bare build can paste one address (or an invite) instead of editing
/// files.
class _RelaySection extends StatefulWidget {
  const _RelaySection();

  @override
  State<_RelaySection> createState() => _RelaySectionState();
}

class _RelaySectionState extends State<_RelaySection> {
  final TextEditingController _url = TextEditingController();

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = SettingsScope.of(context);
    final snapshot = controller.snapshot;
    return SectionCard(
      title: '中继连接',
      subtitle: '如果分发包已带地址，这里可以不改',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            snapshot.relayUrl ?? '未设置（当前为局域网模式）',
            style: AppTheme.mono(
              12.5,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _url,
            decoration: const InputDecoration(
              hintText: 'wss://relay.example.com/ws 或 192.168.1.5:8787',
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            children: <Widget>[
              FilledButton.icon(
                onPressed: _url.text.trim().isEmpty
                    ? null
                    : () => controller.setRelay(url: _url.text.trim()),
                icon: const Icon(Icons.link_rounded, size: 18),
                label: const Text('保存并重启连接'),
              ),
              TextButton(
                onPressed: () => controller.setRelay(clear: true),
                child: const Text('清除地址'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Passes the controller into Settings sub-widgets without threading it through
/// every constructor.
class SettingsScope extends InheritedWidget {
  const SettingsScope({super.key, required this.controller, required super.child});

  final AssistantController controller;

  static AssistantController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<SettingsScope>();
    assert(scope != null, 'SettingsScope is missing above this widget');
    return scope!.controller;
  }

  @override
  bool updateShouldNotify(SettingsScope oldWidget) =>
      controller != oldWidget.controller;
}
