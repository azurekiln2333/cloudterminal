import 'dart:io';

import 'package:flutter/material.dart';

import 'engine/sidecar_client.dart';
import 'screens/home_shell.dart';
import 'state/assistant_controller.dart';
import 'theme/app_theme.dart';

void main() {
  runApp(const CloudTerminalWindowsApp());
}

class CloudTerminalWindowsApp extends StatefulWidget {
  const CloudTerminalWindowsApp({super.key});

  @override
  State<CloudTerminalWindowsApp> createState() =>
      _CloudTerminalWindowsAppState();
}

class _CloudTerminalWindowsAppState extends State<CloudTerminalWindowsApp> {
  late final AssistantController _controller = AssistantController(
    sidecar: SidecarClient(
      executable: _nodeExecutable(),
      arguments: const <String>['src/agent/main.ts', '--sidecar'],
      workingDirectory: _serverDirectory(),
    ),
  );
  Color _seed = AppTheme.seeds.first.$2;
  ThemeMode _mode = ThemeMode.system;

  @override
  void initState() {
    super.initState();
    _controller.start();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'CloudTerminal 助手',
    debugShowCheckedModeBanner: false,
    theme: AppTheme.light(_seed),
    darkTheme: AppTheme.dark(_seed),
    themeMode: _mode,
    home: HomeShell(
      controller: _controller,
      onSeedChanged: (s) => setState(() => _seed = s),
      onModeChanged: (m) => setState(() => _mode = m),
    ),
  );
}

/// The bundled sidecar lives in the repository next to the Windows app during
/// development: `<repo>/apps/cloudterminal_windows` -> `<repo>/server`.
String _serverDirectory() {
  final appDir = Directory.current.path;
  final candidate = File(
    '$appDir${Platform.pathSeparator}..'
    '${Platform.pathSeparator}..'
    '${Platform.pathSeparator}server'
    '${Platform.pathSeparator}src'
    '${Platform.pathSeparator}agent'
    '${Platform.pathSeparator}main.ts',
  );
  if (candidate.existsSync()) {
    return candidate.parent.parent.parent.path;
  }
  return 'server';
}

String _nodeExecutable() =>
    Platform.isWindows ? 'node.exe' : 'node';
