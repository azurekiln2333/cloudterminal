import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/protocol.dart';
import '../state/remote_controller.dart';
import '../state/session_view.dart';
import '../theme/app_theme.dart';
import '../util/format.dart';
import '../widgets/event_tiles.dart';
import '../widgets/permission_card.dart';
import '../widgets/session_card.dart';

/// Live transcript of one session with permission dock and composer.
class SessionScreen extends StatefulWidget {
  const SessionScreen({
    super.key,
    required this.controller,
    required this.view,
  });

  final RemoteController controller;
  final SessionView view;

  @override
  State<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends State<SessionScreen> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  bool _sending = false;
  bool _showJump = false;
  String? _subscribeError;

  RemoteController get _c => widget.controller;
  SessionView get _v => widget.view;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      final show = _scroll.hasClients && _scroll.offset > 400;
      if (show != _showJump) setState(() => _showJump = show);
    });
    _subscribe();
  }

  Future<void> _subscribe() async {
    try {
      await _c.subscribe(_v.id);
      if (mounted && _subscribeError != null) setState(() => _subscribeError = null);
    } on RemoteException catch (e) {
      // Retried automatically after reconnect; show why it's empty meanwhile.
      if (mounted) setState(() => _subscribeError = e.message);
    }
  }

  @override
  void dispose() {
    _c.unsubscribe(_v.id);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await _c.send(_v.id, text);
      _input.clear();
      if (_scroll.hasClients) {
        await _scroll.animateTo(
          0,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    } on RemoteException catch (e) {
      _toast(e.message);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _interrupt() async {
    try {
      await _c.interrupt(_v.id);
    } on RemoteException catch (e) {
      _toast(e.message);
    }
  }

  Future<void> _answer(PermissionRequestEvent r, PermissionAnswer a) async {
    try {
      await _c.respondPermission(
        _v.id,
        r.requestId,
        a.decision,
        message: a.message,
        answers: a.answers,
      );
      await HapticFeedback.lightImpact();
    } on RemoteException catch (e) {
      _toast(e.message);
    }
  }

  Future<void> _setMode(String mode) async {
    try {
      await _c.setMode(_v.id, mode);
      _toast('已切换为「${PermissionModes.label(mode)}」');
    } on RemoteException catch (e) {
      _toast(e.message);
    }
  }

  Future<void> _resume() async {
    final info = _v.info;
    final claudeId = info.claudeSessionId;
    if (claudeId == null) return;
    try {
      final session = await _c.createSession(
        cwd: info.cwd,
        resume: claudeId,
        mode: info.mode,
      );
      if (!mounted) return;
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => SessionScreen(controller: _c, view: _c.view(session)),
        ),
      );
    } on RemoteException catch (e) {
      _toast(e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[_v, _c]),
      builder: (context, _) {
        final info = _v.info;
        final pending = _v.pendingPermissions;
        final listed = <SessionEvent>[
          for (final e in _v.events)
            if (isListed(e, _v)) e,
        ];
        final streaming = _v.streaming;
        final working = info.status == SessionStatus.running &&
            streaming.isEmpty &&
            pending.isEmpty;
        // Reversed list: index 0 is the bottom of the transcript.
        final tail = <Widget>[
          if (working) const _WorkingIndicator(),
          if (streaming.isNotEmpty) AssistantText(text: streaming, streaming: true),
        ];

        return Scaffold(
          appBar: AppBar(
            title: _Header(info: info),
            actions: <Widget>[
              _ModeButton(
                mode: info.mode,
                allowBypass: _c.agent?.allowBypass ?? false,
                enabled: _c.isOnline && !info.isClosed,
                onSelected: _setMode,
              ),
              PopupMenuButton<String>(
                onSelected: (value) async {
                  switch (value) {
                    case 'copy':
                      await Clipboard.setData(ClipboardData(text: info.cwd));
                      _toast('已复制路径');
                    case 'close':
                      try {
                        await _c.closeSession(_v.id);
                        if (context.mounted) Navigator.of(context).pop();
                      } on RemoteException catch (e) {
                        _toast(e.message);
                      }
                  }
                },
                itemBuilder: (context) => <PopupMenuEntry<String>>[
                  const PopupMenuItem<String>(
                    value: 'copy',
                    child: ListTile(
                      leading: Icon(Icons.copy_rounded),
                      title: Text('复制工作目录'),
                    ),
                  ),
                  PopupMenuItem<String>(
                    value: 'close',
                    enabled: _c.isOnline,
                    child: ListTile(
                      leading: const Icon(Icons.delete_outline_rounded),
                      title: Text(info.isClosed ? '从列表移除' : '结束会话'),
                    ),
                  ),
                ],
              ),
            ],
          ),
          body: Column(
            children: <Widget>[
              if (!_c.isOnline) _OfflineStrip(phase: _c.phase),
              Expanded(
                child: Stack(
                  children: <Widget>[
                    if (!_v.loaded && _subscribeError == null)
                      const Center(child: CircularProgressIndicator())
                    else if (_v.gone)
                      const _GoneNotice()
                    else if (listed.isEmpty && tail.isEmpty)
                      _EmptyTranscript(error: _subscribeError)
                    else
                      ListView.builder(
                        controller: _scroll,
                        reverse: true,
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                        itemCount: tail.length + listed.length,
                        itemBuilder: (context, i) {
                          final Widget child;
                          if (i < tail.length) {
                            child = tail[tail.length - 1 - i];
                          } else {
                            final e = listed[listed.length - 1 - (i - tail.length)];
                            child = EventTile(
                              key: ValueKey<int>(e.seq),
                              event: e,
                              view: _v,
                            );
                          }
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 5),
                            child: child,
                          );
                        },
                      ),
                    if (_showJump)
                      Positioned(
                        right: 16,
                        bottom: 12,
                        child: FloatingActionButton.small(
                          heroTag: null,
                          tooltip: '回到最新',
                          onPressed: () => _scroll.animateTo(
                            0,
                            duration: const Duration(milliseconds: 300),
                            curve: Curves.easeOut,
                          ),
                          child: const Icon(Icons.arrow_downward_rounded),
                        ),
                      ),
                  ],
                ),
              ),
              if (pending.isNotEmpty)
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.sizeOf(context).height * 0.6,
                  ),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                    child: PermissionCard(
                      key: ValueKey<String>(pending.first.requestId),
                      request: pending.first,
                      index: 1,
                      total: pending.length,
                      onAnswer: (a) => _answer(pending.first, a),
                    ),
                  ),
                ),
              if (info.isClosed)
                _ClosedBar(
                  canResume: info.claudeSessionId != null && _c.isOnline,
                  onResume: _resume,
                )
              else
                _Composer(
                  controller: _input,
                  enabled: _c.isOnline && !_v.gone,
                  sending: _sending,
                  busy: info.isBusy,
                  onSend: _send,
                  onStop: _interrupt,
                  hint: pending.isNotEmpty ? '也可以直接回复 Claude…' : '给 Claude 发消息…',
                ),
            ],
          ),
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.info});

  final SessionInfo info;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = AppTheme.statusColor(scheme, info.status.name);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(info.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        const SizedBox(height: 2),
        Row(
          children: <Widget>[
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(shape: BoxShape.circle, color: color),
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                '${statusLabel(info.status)} · ${baseName(info.cwd)}'
                '${info.costUsd > 0 ? ' · ${formatCost(info.costUsd)}' : ''}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _ModeButton extends StatelessWidget {
  const _ModeButton({
    required this.mode,
    required this.allowBypass,
    required this.enabled,
    required this.onSelected,
  });

  final String mode;
  final bool allowBypass;
  final bool enabled;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PopupMenuButton<String>(
      tooltip: '权限模式',
      enabled: enabled,
      initialValue: mode,
      onSelected: onSelected,
      itemBuilder: (context) => <PopupMenuEntry<String>>[
        for (final m in PermissionModes.all)
          if (m != PermissionModes.bypass || allowBypass)
            PopupMenuItem<String>(
              value: m,
              child: ListTile(
                leading: Icon(
                  m == mode ? Icons.radio_button_checked : Icons.radio_button_off,
                  color: m == mode ? scheme.primary : null,
                ),
                title: Text(PermissionModes.label(m)),
                subtitle: Text(
                  PermissionModes.description(m),
                  style: const TextStyle(fontSize: 11.5),
                ),
              ),
            ),
      ],
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 4),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: scheme.secondaryContainer,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.shield_outlined, size: 16, color: scheme.onSecondaryContainer),
            const SizedBox(width: 4),
            Text(
              PermissionModes.label(mode),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: scheme.onSecondaryContainer,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.enabled,
    required this.sending,
    required this.busy,
    required this.onSend,
    required this.onStop,
    required this.hint,
  });

  final TextEditingController controller;
  final bool enabled;
  final bool sending;
  final bool busy;
  final VoidCallback onSend;
  final VoidCallback onStop;
  final String hint;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainer,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: controller,
                  enabled: enabled,
                  minLines: 1,
                  maxLines: 6,
                  textInputAction: TextInputAction.newline,
                  decoration: InputDecoration(
                    hintText: enabled ? hint : '电脑未连接',
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide.none,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide.none,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide(color: scheme.primary),
                    ),
                    fillColor: scheme.surfaceContainerHighest,
                  ),
                ),
              ),
              if (busy) ...<Widget>[
                const SizedBox(width: 4),
                IconButton.filledTonal(
                  tooltip: '停止',
                  onPressed: enabled ? onStop : null,
                  icon: const Icon(Icons.stop_rounded),
                ),
              ],
              const SizedBox(width: 4),
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: controller,
                builder: (context, value, _) => IconButton.filled(
                  tooltip: '发送',
                  onPressed: enabled && !sending && value.text.trim().isNotEmpty
                      ? onSend
                      : null,
                  icon: sending
                      ? SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: scheme.onPrimary,
                          ),
                        )
                      : const Icon(Icons.arrow_upward_rounded),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WorkingIndicator extends StatelessWidget {
  const _WorkingIndicator();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: <Widget>[
        SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2, color: scheme.primary),
        ),
        const SizedBox(width: 10),
        Text(
          'Claude 正在工作…',
          style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

class _OfflineStrip extends StatelessWidget {
  const _OfflineStrip({required this.phase});

  final ConnectionPhase phase;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = switch (phase) {
      ConnectionPhase.connecting => '正在重新连接…',
      ConnectionPhase.agentOffline => '电脑离线，恢复后会自动同步',
      ConnectionPhase.authFailed => '配对已失效',
      _ => '网络断开，正在重试…',
    };
    return Container(
      width: double.infinity,
      color: scheme.secondaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Text(
        text,
        style: TextStyle(fontSize: 12, color: scheme.onSecondaryContainer),
      ),
    );
  }
}

class _ClosedBar extends StatelessWidget {
  const _ClosedBar({required this.canResume, required this.onResume});

  final bool canResume;
  final VoidCallback onResume;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainer,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
          child: Row(
            children: <Widget>[
              Icon(Icons.check_circle_outline_rounded, color: scheme.outline),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '会话已结束',
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              ),
              FilledButton.tonalIcon(
                onPressed: canResume ? onResume : null,
                icon: const Icon(Icons.replay_rounded),
                label: const Text('继续这个会话'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GoneNotice extends StatelessWidget {
  const _GoneNotice();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.link_off_rounded, size: 44, color: scheme.outline),
            const SizedBox(height: 12),
            const Text('这个会话已不在电脑上'),
            const SizedBox(height: 6),
            Text(
              '可能已被结束，或者 agent 重启过。可以从历史会话里继续。',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyTranscript extends StatelessWidget {
  const _EmptyTranscript({this.error});

  final String? error;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          error ?? '发一条消息，让 Claude 开始工作',
          textAlign: TextAlign.center,
          style: TextStyle(color: error == null ? scheme.onSurfaceVariant : scheme.error),
        ),
      ),
    );
  }
}
