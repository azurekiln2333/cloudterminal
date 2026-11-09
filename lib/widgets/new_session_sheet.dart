import 'package:flutter/material.dart';

import '../models/protocol.dart';
import '../state/remote_controller.dart';
import '../theme/app_theme.dart';
import '../util/format.dart';
import 'dir_picker_sheet.dart';
import 'section_label.dart';

/// Start a terminal or Claude session on the PC. Returns the created session.
Future<SessionInfo?> showNewSessionSheet(
  BuildContext context,
  RemoteController controller, {
  String? initialCwd,
}) {
  return showModalBottomSheet<SessionInfo>(
    context: context,
    isScrollControlled: true,
    // A visible grab handle: without one the sheet looked like a dead panel on
    // the phone, and the only way out was the system back gesture.
    showDragHandle: true,
    useSafeArea: true,
    builder: (context) => _NewSessionSheet(
      controller: controller,
      initialCwd: initialCwd ?? controller.agent?.defaultCwd ?? '',
    ),
  );
}

class _NewSessionSheet extends StatefulWidget {
  const _NewSessionSheet({required this.controller, required this.initialCwd});

  final RemoteController controller;
  final String initialCwd;

  @override
  State<_NewSessionSheet> createState() => _NewSessionSheetState();
}

class _NewSessionSheetState extends State<_NewSessionSheet> {
  late String _cwd = widget.initialCwd;
  final TextEditingController _prompt = TextEditingController();
  String _mode = PermissionModes.defaultMode;
  late bool _terminal =
      widget.controller.agent?.capabilities.contains('terminal') ?? false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _prompt.dispose();
    super.dispose();
  }

  Future<void> _pickDir() async {
    final picked = await showDirPickerSheet(
      context,
      widget.controller,
      initialPath: _cwd,
    );
    if (picked != null && mounted) {
      setState(() {
        _cwd = picked;
        // A previous failure no longer describes the form on screen.
        _error = null;
      });
    }
  }

  Future<void> _start() async {
    // Drop the keyboard before the modal closes, otherwise it stays up over the
    // session that is about to open behind it.
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final session = _terminal
          ? await widget.controller.createTerminal(cwd: _cwd)
          : await widget.controller.createSession(
              cwd: _cwd,
              prompt: _prompt.text,
              mode: _mode,
            );
      if (mounted) Navigator.of(context).pop(session);
    } on RemoteException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final allowBypass = widget.controller.agent?.allowBypass ?? false;
    final modes = <String>[
      for (final m in PermissionModes.all)
        if (m != PermissionModes.bypass || allowBypass) m,
    ];

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text('新建会话', style: theme.textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(
                '在 ${widget.controller.agentName} 上启动${_terminal ? '终端，可运行任意命令行工具' : ' Claude Code'}。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 18),
              if (widget.controller.agent?.capabilities.contains('terminal') ??
                  false) ...<Widget>[
                SegmentedButton<bool>(
                  segments: const <ButtonSegment<bool>>[
                    ButtonSegment(
                      value: true,
                      label: Text('终端'),
                      icon: Icon(Icons.terminal),
                    ),
                    ButtonSegment(value: false, label: Text('Claude')),
                  ],
                  selected: <bool>{_terminal},
                  onSelectionChanged: _busy
                      ? null
                      : (v) => setState(() {
                          _terminal = v.single;
                          _error = null;
                        }),
                ),
                const SizedBox(height: 18),
              ],
              const SectionLabel('工作目录'),
              const SizedBox(height: 8),
              Material(
                color: scheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(12),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: _busy ? null : _pickDir,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    child: Row(
                      children: <Widget>[
                        Icon(Icons.folder_open_rounded, color: scheme.primary),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                _cwd.isEmpty ? '点击选择' : baseName(_cwd),
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              if (_cwd.isNotEmpty)
                                Text(
                                  _cwd,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppTheme.mono(
                                    11.5,
                                    color: scheme.onSurfaceVariant,
                                    height: 1.3,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        Icon(
                          Icons.unfold_more_rounded,
                          color: scheme.onSurfaceVariant,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              if (!_terminal) ...<Widget>[
                const SectionLabel('要做什么'),
                const SizedBox(height: 8),
                TextField(
                  controller: _prompt,
                  minLines: 3,
                  maxLines: 8,
                  textInputAction: TextInputAction.newline,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    hintText: '例如：修复登录页的单元测试并提交',
                  ),
                ),
                const SizedBox(height: 18),
                const SectionLabel('权限模式'),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: _mode,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.shield_outlined),
                  ),
                  items: <DropdownMenuItem<String>>[
                    for (final m in modes)
                      DropdownMenuItem<String>(
                        value: m,
                        child: Text(PermissionModes.label(m)),
                      ),
                  ],
                  onChanged: _busy ? null : (m) => setState(() => _mode = m!),
                ),
                const SizedBox(height: 6),
                Text(
                  PermissionModes.description(_mode),
                  style: TextStyle(
                    fontSize: 12,
                    color: _mode == PermissionModes.bypass
                        ? scheme.error
                        : scheme.onSurfaceVariant,
                  ),
                ),
              ],
              if (_error != null) ...<Widget>[
                const SizedBox(height: 14),
                Text(_error!, style: TextStyle(color: scheme.error)),
              ],
              const SizedBox(height: 22),
              FilledButton.icon(
                onPressed: _busy || _cwd.isEmpty ? null : _start,
                icon: _busy
                    ? SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: scheme.onPrimary,
                        ),
                      )
                    : const Icon(Icons.play_arrow_rounded),
                label: Text(
                  _terminal || _prompt.text.trim().isEmpty ? '启动' : '启动并发送',
                ),
              ),
              // A disabled button with no explanation is a dead end: say what is
              // missing instead of leaving the user to guess.
              if (_cwd.isEmpty) ...<Widget>[
                const SizedBox(height: 8),
                Text(
                  '先选择工作目录才能启动。',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
