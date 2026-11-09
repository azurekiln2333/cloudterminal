import 'package:flutter/material.dart';

import '../state/assistant_controller.dart';
import '../theme/app_theme.dart';
import 'overview_page.dart';
import 'pairing_page.dart';
import 'sessions_page.dart';
import 'settings_page.dart';
import 'tools_page.dart';

/// Standard Material 3 shell: NavigationRail on wide windows, NavigationDrawer
/// on narrow ones. Five destinations, no bespoke chrome.
class HomeShell extends StatefulWidget {
  const HomeShell({
    super.key,
    required this.controller,
    required this.onSeedChanged,
    required this.onModeChanged,
  });

  final AssistantController controller;
  final ValueChanged<Color> onSeedChanged;
  final ValueChanged<ThemeMode> onModeChanged;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  static const List<(IconData, IconData, String)> _destinations =
      <(IconData, IconData, String)>[
        (Icons.dashboard_outlined, Icons.dashboard_rounded, '总览'),
        (Icons.extension_outlined, Icons.extension_rounded, '工具'),
        (Icons.forum_outlined, Icons.forum_rounded, '会话'),
        (Icons.qr_code_2_outlined, Icons.qr_code_2_rounded, '配对'),
        (Icons.settings_outlined, Icons.settings_rounded, '设置'),
      ];

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final wide = MediaQuery.sizeOf(context).width >= 900;
      final body = IndexedStack(
        index: _index,
        children: <Widget>[
          OverviewPage(controller: widget.controller),
          ToolsPage(controller: widget.controller),
          SessionsPage(controller: widget.controller),
          PairingPage(controller: widget.controller),
          SettingsPage(
            controller: widget.controller,
            onSeedChanged: widget.onSeedChanged,
            onModeChanged: widget.onModeChanged,
          ),
        ],
      );
      if (wide) {
        return Scaffold(
          body: Row(
            children: <Widget>[
              NavigationRail(
                selectedIndex: _index,
                onDestinationSelected: (i) => setState(() => _index = i),
                labelType: NavigationRailLabelType.all,
                leading: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Icon(Icons.terminal_rounded),
                ),
                destinations: <NavigationRailDestination>[
                  for (final (icon, selected, label) in _destinations)
                    NavigationRailDestination(
                      icon: Icon(icon),
                      selectedIcon: Icon(selected),
                      label: Text(label),
                    ),
                ],
              ),
              const VerticalDivider(width: 1),
              Expanded(child: body),
            ],
          ),
        );
      }
      return Scaffold(
        appBar: AppBar(title: Text(_destinations[_index].$3)),
        drawer: NavigationDrawer(
          selectedIndex: _index,
          onDestinationSelected: (i) {
            setState(() => _index = i);
            Navigator.of(context).pop();
          },
          children: <Widget>[
            const Padding(
              padding: EdgeInsets.fromLTRB(28, 20, 16, 10),
              child: Text(
                'CloudTerminal 助手',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ),
            for (final (icon, selected, label) in _destinations)
              NavigationDrawerDestination(
                icon: Icon(icon),
                selectedIcon: Icon(selected),
                label: Text(label),
              ),
          ],
        ),
        body: body,
      );
    },
  );
}

/// Shared page scaffold used by every destination.
class PageScaffold extends StatelessWidget {
  const PageScaffold({
    super.key,
    required this.title,
    this.subtitle,
    this.actions,
    required this.child,
  });

  final String title;
  final String? subtitle;
  final List<Widget>? actions;
  final Widget child;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.transparent,
    appBar: AppBar(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(title, style: const TextStyle(fontSize: 18)),
          if (subtitle != null)
            Text(
              subtitle!,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w400),
            ),
        ],
      ),
      actions: actions,
    ),
    body: child,
  );
}

/// Standard empty/error state with an actionable message.
class MessageState extends StatelessWidget {
  const MessageState({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    this.action,
  });

  final IconData icon;
  final String title;
  final String body;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 54, color: scheme.outline),
              const SizedBox(height: 16),
              Text(
                title,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                body,
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant, height: 1.5),
              ),
              if (action != null) ...<Widget>[
                const SizedBox(height: 20),
                action!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Small helper reused by pages that show the relay status.
String relayStatusText(AssistantController controller) {
  final s = controller.snapshot;
  if (s.relayOnline) return '中继已连接';
  if (s.retries > 0) return '离线（重试中，第 ${s.retries} 次）';
  return '未连接中继';
}

Color relayStatusColor(BuildContext context, AssistantController controller) {
  final s = controller.snapshot;
  if (s.relayOnline) return const Color(0xFF15803D);
  if (s.retries > 0) return const Color(0xFFB45309);
  return Theme.of(context).colorScheme.error;
}

/// Re-exported so pages share the mono style without importing the theme twice.
TextStyle monoStyle(double size, {Color? color}) =>
    AppTheme.mono(size, color: color);
