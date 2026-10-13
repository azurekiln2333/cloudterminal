import 'dart:async';

import 'package:flutter/material.dart';

import '../models/herdr.dart';
import '../state/herdr_controller.dart';
import '../state/remote_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/herdr_pane_viewport.dart';
import '../widgets/herdr_status.dart';

/// Shows one Herdr pane: its real screen output, an input bar and the controls
/// that Herdr actually supports for it.
class HerdrPaneScreen extends StatefulWidget {
  const HerdrPaneScreen({
    super.key,
    required this.controller,
    required this.herdr,
    required this.workspace,
    required this.pane,
  });

  final RemoteController controller;
  final HerdrController herdr;
  final HerdrWorkspace workspace;
  final HerdrPane pane;

  @override
  State<HerdrPaneScreen> createState() => _HerdrPaneScreenState();
}

class _HerdrPaneScreenState extends State<HerdrPaneScreen> {
  final ScrollController _scroll = ScrollController();
  final TextEditingController _input = TextEditingController();

  HerdrReadSource _source = HerdrReadSource.visible;
  int _lines = 200;
  HerdrOutput? _output;
  bool _loading = true;
  bool _sending = false;
  String? _error;

  /// Bumped on every completed read so the viewport can tell a fresh screen
  /// from an ordinary rebuild. Two reads can return identical text, so the
  /// content itself cannot be used as the identity.
  int _loadGeneration = 0;
  HerdrViewportMode _viewMode = HerdrViewportMode.fitWidth;
  double _fontSize = 12;

  /// The desktop pane's column count, from its layout. Only used to keep the
  /// desktop's own wrapping in [HerdrViewportMode.rawColumns]; null means the
  /// viewport infers it from the content.
  int? get _sourceColumns {
    final layout = widget.herdr.layout(widget.pane.paneId);
    final width = layout?.area.width ?? 0;
    return width >= 20 ? width : null;
  }

  HerdrPane get _pane => widget.herdr
      .panes(widget.workspace.workspaceId)
      .firstWhere(
        (p) => p.paneId == widget.pane.paneId,
        orElse: () => widget.pane,
      );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    _input.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!widget.herdr.canControl) {
      setState(() {
        _loading = false;
        _error = widget.herdr.availability?.summary ?? 'Herdr 不可用';
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final output = await widget.herdr.read(
        widget.pane.paneId,
        source: _source,
        lines: _lines,
      );
      // Only replace the existing output once the new one has arrived: the
      // viewport must keep showing what the user is reading while a read is in
      // flight.
      if (mounted) {
        setState(() {
          _output = output;
          _loadGeneration++;
        });
      }
    } on RemoteException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<bool> _act(
    String key,
    Future<HerdrActionReport> Function() action, {
    bool refreshOutput = true,
  }) async {
    if (_sending) return false;
    setState(() => _sending = true);
    try {
      final report = await widget.herdr.run(key, action);
      if (report != null && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(report.summary)));
      }
      if (refreshOutput) await _load();
      return report != null;
    } on RemoteException catch (e) {
      if (mounted) {
        // Deliberately no automatic retry: a stalled prompt or a blocked agent
        // must be inspected on the desktop, never resent blindly.
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.message),
            duration: const Duration(seconds: 6),
          ),
        );
      }
      return false;
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// Send text to the agent when the pane hosts one, otherwise to the terminal.
  Future<void> _send() async {
    final text = _input.text;
    if (text.trim().isEmpty || _sending) return;
    final pane = _pane;
    final ok = pane.hostsAgent
        ? await _act(
            'prompt:${pane.agentTarget}',
            () => widget.controller.herdrPrompt(
              pane.agentTarget,
              text,
              wait: false,
            ),
          )
        : await _act(
            'send_text:${pane.paneId}',
            () => widget.controller.herdrSendText(pane.paneId, text),
          );
    if (ok && mounted) _input.clear();
  }

  Future<void> _sendKey(String key) async {
    final pane = _pane;
    final target = pane.hostsAgent ? pane.agentTarget : pane.paneId;
    await _act(
      'keys:$target',
      () => widget.controller.herdrSendKeys(target, <String>[key]),
    );
  }

  Future<void> _runCommand() async {
    final command = await showDialog<String>(
      context: context,
      builder: (context) => const _CommandDialog(),
    );
    if (command == null || !mounted) return;
    final pane = _pane;
    await _act(
      'run:${pane.paneId}',
      () => widget.controller.herdrRun(pane.paneId, command),
    );
  }

  Future<void> _confirmClose({
    required String title,
    required String body,
    required Future<void> Function() onConfirm,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.warning_amber_rounded),
        title: Text(title),
        content: Text(body),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('确认关闭'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await onConfirm();
    }
  }

  Future<void> _controls() async {
    final pane = _pane;
    final action = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const ListTile(
                dense: true,
                title: Text(
                  '面板操作',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.splitscreen_rounded),
                title: const Text('向右拆分'),
                subtitle: const Text('新面板保留当前目录'),
                onTap: () => Navigator.of(context).pop('split_right'),
              ),
              ListTile(
                leading: const Icon(Icons.splitscreen_rounded),
                title: const Text('向下拆分'),
                onTap: () => Navigator.of(context).pop('split_down'),
              ),
              ListTile(
                leading: const Icon(Icons.zoom_out_map_rounded),
                title: const Text('切换缩放'),
                onTap: () => Navigator.of(context).pop('zoom'),
              ),
              ListTile(
                leading: const Icon(Icons.arrow_upward_rounded),
                title: const Text('向上扩大'),
                onTap: () => Navigator.of(context).pop('grow_up'),
              ),
              ListTile(
                leading: const Icon(Icons.open_in_new_rounded),
                title: const Text('聚焦该面板'),
                subtitle: const Text('把电脑上的 Herdr 焦点切换过来'),
                onTap: () => Navigator.of(context).pop('focus'),
              ),
              if (!pane.hostsAgent)
                ListTile(
                  leading: const Icon(Icons.play_circle_outline_rounded),
                  title: const Text('在此面板启动 agent'),
                  subtitle: const Text('需要面板处于空闲 shell 提示符'),
                  onTap: () => Navigator.of(context).pop('start_agent'),
                ),
              ListTile(
                leading: const Icon(Icons.swap_horiz_rounded),
                title: const Text('移动到新标签页'),
                onTap: () => Navigator.of(context).pop('move_tab'),
              ),
              ListTile(
                leading: const Icon(Icons.copy_all_rounded),
                title: const Text('移动到新工作区'),
                onTap: () => Navigator.of(context).pop('move_workspace'),
              ),
              const Divider(height: 1),
              ListTile(
                leading: Icon(
                  Icons.close_rounded,
                  color: Theme.of(context).colorScheme.error,
                ),
                title: const Text('关闭面板'),
                subtitle: Text(
                  pane.hostsAgent ? '其中的 agent 也会被结束' : '面板中的进程会被结束',
                ),
                onTap: () => Navigator.of(context).pop('close'),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'split_right':
        await _act(
          'split:${pane.paneId}',
          () => widget.controller.herdrAct(
            HerdrActions.paneSplit(
              pane.paneId,
              'right',
              cwd: pane.cwd.isEmpty ? null : pane.cwd,
              focus: false,
            ),
          ),
          refreshOutput: false,
        );
      case 'split_down':
        await _act(
          'split:${pane.paneId}',
          () => widget.controller.herdrAct(
            HerdrActions.paneSplit(
              pane.paneId,
              'down',
              cwd: pane.cwd.isEmpty ? null : pane.cwd,
              focus: false,
            ),
          ),
          refreshOutput: false,
        );
      case 'zoom':
        await _act(
          'zoom:${pane.paneId}',
          () => widget.controller.herdrAct(HerdrActions.paneZoom(pane.paneId)),
          refreshOutput: false,
        );
      case 'grow_up':
        await _act(
          'resize:${pane.paneId}',
          () => widget.controller.herdrAct(
            HerdrActions.paneResize(pane.paneId, 'up', amount: 0.1),
          ),
          refreshOutput: false,
        );
      case 'focus':
        await _act(
          'focus:${pane.paneId}',
          () => widget.controller.herdrAct(HerdrActions.paneFocus(pane.paneId)),
          refreshOutput: false,
        );
      case 'start_agent':
        if (mounted) await _startAgent(pane);
      case 'move_tab':
        await _act(
          'move:${pane.paneId}',
          () => widget.controller.herdrAct(
            HerdrActions.paneMoveToNewTab(pane.paneId),
          ),
          refreshOutput: false,
        );
        if (mounted) Navigator.of(context).maybePop();
      case 'move_workspace':
        await _act(
          'move:${pane.paneId}',
          () => widget.controller.herdrAct(
            HerdrActions.paneMoveToNewWorkspace(pane.paneId),
          ),
          refreshOutput: false,
        );
        if (mounted) Navigator.of(context).maybePop();
      case 'close':
        await _confirmClose(
          title: '关闭 ${pane.paneId}？',
          body: pane.hostsAgent
              ? '这会结束 ${pane.name ?? pane.agent} 以及其中的进程，无法撤销。'
              : '这会结束面板中的进程，无法撤销。',
          onConfirm: () async {
            final ok = await _act(
              'close:${pane.paneId}',
              () => widget.controller.herdrAct(
                HerdrActions.paneClose(pane.paneId),
              ),
              refreshOutput: false,
            );
            if (ok && mounted) Navigator.of(context).maybePop();
          },
        );
    }
  }

  Future<void> _startAgent(HerdrPane pane) async {
    final result = await showDialog<({String name, String kind})>(
      context: context,
      builder: (context) => const _StartAgentDialog(),
    );
    if (result == null || !mounted) return;
    final ok = await _act(
      'agent_start:${pane.paneId}',
      () => widget.controller.herdrAct(
        HerdrActions.agentStart(result.name, result.kind, pane.paneId),
      ),
      refreshOutput: false,
    );
    if (ok && mounted) {
      await widget.herdr.loadWorkspace(pane.workspaceId, force: true);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge(<Listenable>[widget.herdr, widget.controller]),
    builder: (context, _) {
      final pane = _pane;
      return Scaffold(
        appBar: AppBar(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                pane.terminalTitle.isEmpty ? pane.paneId : pane.terminalTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                '${widget.workspace.displayLabel} · ${pane.paneId}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ),
          actions: <Widget>[
            IconButton(
              tooltip: '刷新输出',
              onPressed: _loading ? null : _load,
              icon: const Icon(Icons.refresh_rounded),
            ),
            IconButton(
              tooltip: '面板操作',
              onPressed: widget.herdr.canControl && !_sending
                  ? _controls
                  : null,
              icon: const Icon(Icons.tune_rounded),
            ),
          ],
        ),
        body: Column(
          children: <Widget>[
            _meta(context, pane),
            if (_error != null) _errorBanner(context),
            _sourceBar(context),
            if (_scrollReviewing) _scrollReviewBanner(context),
            if (_sending || (_loading && _output != null))
              const LinearProgressIndicator(minHeight: 2),
            Expanded(child: _outputView(context)),
            _inputBar(context, pane),
          ],
        ),
      );
    },
  );

  Widget _meta(BuildContext context, HerdrPane pane) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      color: scheme.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              if (pane.agentStatus != null) ...<Widget>[
                HerdrStatusChip(status: pane.agentStatus!),
                const SizedBox(width: 8),
              ],
              if (pane.hostsAgent)
                Text(
                  pane.name ?? pane.agent!,
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                )
              else
                Text(
                  '空闲终端',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              if (pane.focused) ...<Widget>[
                const SizedBox(width: 8),
                Icon(Icons.visibility_rounded, size: 14, color: scheme.primary),
                const SizedBox(width: 2),
                Text(
                  '电脑焦点',
                  style: TextStyle(fontSize: 11, color: scheme.primary),
                ),
              ],
            ],
          ),
          if (pane.agentStatus != null) ...<Widget>[
            const SizedBox(height: 4),
            Text(
              herdrStatusHint(pane.agentStatus!),
              style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
            ),
          ],
          const SizedBox(height: 4),
          HerdrPath(pane.cwd),
        ],
      ),
    );
  }

  Widget _errorBanner(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: <Widget>[
          Icon(
            Icons.error_outline_rounded,
            size: 18,
            color: scheme.onErrorContainer,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _error!,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.4,
                color: scheme.onErrorContainer,
              ),
            ),
          ),
          TextButton(onPressed: _load, child: const Text('重试')),
        ],
      ),
    );
  }

  Widget _sourceBar(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Row(
        children: <Widget>[
          for (final source in HerdrReadSource.values)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ChoiceChip(
                label: Text(source.label),
                selected: _source == source,
                onSelected: (_) {
                  if (_source == source) return;
                  setState(() => _source = source);
                  _load();
                },
              ),
            ),
          const SizedBox(width: 4),
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: ChoiceChip(
              avatar: Icon(
                _viewMode == HerdrViewportMode.fitWidth
                    ? Icons.fit_screen_rounded
                    : Icons.open_in_full_rounded,
                size: 15,
              ),
              label: Text(_viewMode.label),
              selected: false,
              tooltip: _viewMode.hint,
              onSelected: (_) {
                setState(() {
                  _viewMode = _viewMode == HerdrViewportMode.fitWidth
                      ? HerdrViewportMode.rawColumns
                      : HerdrViewportMode.fitWidth;
                });
                // The desktop column count is only needed for the un-wrapped
                // mode, and fetching it is a cached no-op afterwards.
                if (_viewMode == HerdrViewportMode.rawColumns) {
                  unawaited(widget.herdr.loadLayout(_pane.paneId));
                }
              },
            ),
          ),
          PopupMenuButton<double>(
            tooltip: '字号',
            initialValue: _fontSize,
            onSelected: (value) => setState(() => _fontSize = value),
            itemBuilder: (context) => const <PopupMenuEntry<double>>[
              PopupMenuItem<double>(value: 10, child: Text('字号 10')),
              PopupMenuItem<double>(value: 11, child: Text('字号 11')),
              PopupMenuItem<double>(value: 12, child: Text('字号 12')),
              PopupMenuItem<double>(value: 13, child: Text('字号 13')),
              PopupMenuItem<double>(value: 14, child: Text('字号 14')),
            ],
            child: Chip(
              avatar: Icon(
                Icons.format_size_rounded,
                size: 15,
                color: scheme.onSurfaceVariant,
              ),
              label: Text('${_fontSize.toInt()} 号'),
            ),
          ),
          PopupMenuButton<int>(
            tooltip: '读取行数',
            initialValue: _lines,
            onSelected: (value) {
              setState(() => _lines = value);
              _load();
            },
            itemBuilder: (context) => const <PopupMenuEntry<int>>[
              PopupMenuItem<int>(value: 60, child: Text('60 行')),
              PopupMenuItem<int>(value: 120, child: Text('120 行')),
              PopupMenuItem<int>(value: 200, child: Text('200 行')),
              PopupMenuItem<int>(value: 500, child: Text('500 行')),
              PopupMenuItem<int>(value: 1000, child: Text('1000 行')),
            ],
            child: Chip(
              avatar: Icon(
                Icons.format_list_numbered_rounded,
                size: 15,
                color: scheme.onSurfaceVariant,
              ),
              label: Text('$_lines 行'),
            ),
          ),
        ],
      ),
    );
  }

  /// The desktop Herdr pane's own scroll position, if the agent reported one.
  ///
  /// This is *not* the app's viewport scroll position: it describes where the
  /// PC-side Herdr pane is looking. The UI must say "电脑端" so the two are
  /// never conflated.
  HerdrScroll? get _desktopScroll => _pane.scroll;

  bool get _scrollReviewing {
    final scroll = _desktopScroll;
    return scroll != null && scroll.offsetFromBottom > 0;
  }

  Widget _scrollReviewBanner(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final scroll = _desktopScroll!;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      alignment: Alignment.centerLeft,
      child: Material(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          // Re-reads the latest output. It does NOT change the desktop pane's
          // scroll position: Herdr offers no command for that, and pretending
          // otherwise would be a fabricated capability.
          onTap: _loading ? null : _load,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(
                  Icons.history_rounded,
                  size: 15,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Text(
                  '电脑端回看了 ${scroll.offsetFromBottom} 行',
                  style: TextStyle(fontSize: 11.5, color: scheme.onSurface),
                ),
                const SizedBox(width: 8),
                Text(
                  '重新读取',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: scheme.primary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _outputView(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final output = _output;
    if (_loading && output == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (output == null || output.isBlank) {
      // ignore: prefer_const_constructors
      return ListView(
        controller: _scroll,
        padding: const EdgeInsets.all(24),
        children: <Widget>[
          Icon(Icons.notes_rounded, size: 44, color: scheme.outline),
          const SizedBox(height: 12),
          Text(
            _error == null ? '这个来源没有可显示的输出' : '读取失败',
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          Center(
            child: OutlinedButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('重新读取'),
            ),
          ),
        ],
      );
    }
    // A real terminal emulator, not a text widget: the raw screen text is
    // hard-wrapped for a ~76 column desktop pane, and only terminal reflow can
    // tell a wrap from a newline and re-lay it out for the phone's width.
    return HerdrPaneViewport(
      outputKey: '${widget.pane.paneId}#$_loadGeneration',
      text: output.text,
      mode: _viewMode,
      sourceColumns: _sourceColumns,
      fontSize: _fontSize,
      scrollController: _scroll,
    );
  }

  Widget _inputBar(BuildContext context, HerdrPane pane) {
    final scheme = Theme.of(context).colorScheme;
    final sendLabel = pane.hostsAgent ? '发送' : '写入';
    return Container(
      color: scheme.surfaceContainer,
      child: SafeArea(
        top: false,
        child: Column(
          children: <Widget>[
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
              child: Row(
                children: <Widget>[
                  for (final (key, label) in herdrKeys)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: OutlinedButton(
                        onPressed: widget.herdr.canControl && !_sending
                            ? () => _sendKey(key)
                            : null,
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: Text(
                          label,
                          style: AppTheme.mono(
                            11,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                  if (!pane.hostsAgent)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: OutlinedButton.icon(
                        onPressed: widget.herdr.canControl && !_sending
                            ? _runCommand
                            : null,
                        icon: const Icon(Icons.play_arrow_rounded, size: 15),
                        label: const Text('运行命令'),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: <Widget>[
                  Expanded(
                    child: TextField(
                      controller: _input,
                      // Single-line, like terminax: a multi-line field makes the
                      // IME force its return key to "newline" and swallow
                      // TextInputAction.send, which is why the key did nothing.
                      maxLines: 1,
                      enabled: widget.herdr.canControl,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) {
                        if (widget.herdr.canControl && !_sending) _send();
                      },
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: pane.hostsAgent
                            ? '给 ${pane.name ?? pane.agent} 发送任务…'
                            : '向终端写入文本（不会自动回车）…',
                        helperText: pane.hostsAgent
                            ? '通过 Herdr 的 agent prompt 提交，文本和回车一起发送'
                            : null,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  // Disabled while a send is in flight: this is what stops a
                  // double tap from submitting the same task twice.
                  IconButton.filled(
                    tooltip: sendLabel,
                    onPressed: widget.herdr.canControl && !_sending
                        ? _send
                        : null,
                    icon: const Icon(Icons.send_rounded),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CommandDialog extends StatefulWidget {
  const _CommandDialog();

  @override
  State<_CommandDialog> createState() => _CommandDialogState();
}

class _CommandDialogState extends State<_CommandDialog> {
  final TextEditingController _input = TextEditingController();

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('在面板中运行命令'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Text(
          '命令会在该面板的 shell 中执行。参数不会被当作 shell 拼接，'
          '就是你输入的原始一行命令。',
          style: TextStyle(fontSize: 12.5),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _input,
          autofocus: true,
          maxLines: 3,
          minLines: 1,
          style: AppTheme.mono(13),
          decoration: const InputDecoration(hintText: '例如 git status'),
          onChanged: (_) => setState(() {}),
        ),
      ],
    ),
    actions: <Widget>[
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: _input.text.trim().isEmpty
            ? null
            : () => Navigator.of(context).pop(_input.text),
        child: const Text('运行'),
      ),
    ],
  );
}

class _StartAgentDialog extends StatefulWidget {
  const _StartAgentDialog();

  @override
  State<_StartAgentDialog> createState() => _StartAgentDialogState();
}

class _StartAgentDialogState extends State<_StartAgentDialog> {
  final TextEditingController _name = TextEditingController();
  String _kind = herdrAgentKinds.first;
  String? _nameError;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  /// Mirrors Herdr's own rule: `[a-z][a-z0-9_-]{0,31}`.
  String? _validate(String value) {
    if (value.isEmpty) return '请填写 agent 名称';
    if (!RegExp(r'^[a-z][a-z0-9_-]{0,31}$').hasMatch(value)) {
      return '只能用小写字母、数字、下划线和连字符，并以字母开头';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('启动 agent'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text(
            '需要在空闲 shell 提示符的面板中启动，Herdr 才能识别 agent 状态。',
            style: TextStyle(fontSize: 12.5),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _name,
            autofocus: true,
            decoration: InputDecoration(
              labelText: 'agent 名称',
              hintText: '例如 reviewer',
              errorText: _nameError,
            ),
            onChanged: (_) => setState(() => _nameError = null),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _kind,
            decoration: const InputDecoration(labelText: '类型'),
            items: <DropdownMenuItem<String>>[
              for (final kind in herdrAgentKinds)
                DropdownMenuItem<String>(value: kind, child: Text(kind)),
            ],
            onChanged: (value) => setState(() => _kind = value ?? _kind),
          ),
        ],
      ),
    ),
    actions: <Widget>[
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () {
          final name = _name.text.trim();
          final error = _validate(name);
          if (error != null) {
            setState(() => _nameError = error);
            return;
          }
          Navigator.of(context).pop((name: name, kind: _kind));
        },
        child: const Text('启动'),
      ),
    ],
  );
}
