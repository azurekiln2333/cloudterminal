import 'dart:async';

import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import '../models/protocol.dart';
import '../state/remote_controller.dart';
import '../state/session_view.dart';

/// Interactive terminal; SessionView owns the emulator across navigation.
class TerminalPane extends StatefulWidget {
  const TerminalPane({
    super.key,
    required this.controller,
    required this.view,
    this.subscribeError,
  });
  final RemoteController controller;
  final SessionView view;
  final String? subscribeError;

  @override
  State<TerminalPane> createState() => _TerminalPaneState();
}

class _TerminalPaneState extends State<TerminalPane> {
  Terminal? _bound;
  Timer? _resizeTimer;
  bool _wasEnabled = false;
  String? _error;

  bool get _enabled =>
      widget.controller.isOnline &&
      widget.view.loaded &&
      !widget.view.gone &&
      !widget.view.info.isClosed;

  @override
  void initState() {
    super.initState();
    widget.view.onTerminalInput = _input;
  }

  void _input(String data) {
    if (!_enabled) return;
    unawaited(
      _request(() => widget.controller.terminalInput(widget.view.id, data)),
    );
  }

  Future<void> _request(Future<void> Function() action) async {
    try {
      await action();
      if (mounted && _error != null) setState(() => _error = null);
    } on RemoteException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  void _resize(int cols, int rows, int pixelWidth, int pixelHeight) {
    _resizeTimer?.cancel();
    _resizeTimer = Timer(const Duration(milliseconds: 150), () {
      if (!_enabled) return;
      unawaited(
        _request(
          () => widget.controller.terminalResize(
            widget.view.id,
            cols.clamp(2, 500),
            rows.clamp(1, 300),
          ),
        ),
      );
    });
  }

  @override
  void dispose() {
    widget.view.onTerminalInput = null;
    _bound?.onResize = null;
    _resizeTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final terminal = widget.view.terminal;
    final enabled = _enabled;
    if (!identical(terminal, _bound)) {
      _bound?.onResize = null;
      _bound = terminal;
      terminal.onResize = _resize;
      _resize(terminal.viewWidth, terminal.viewHeight, 0, 0);
    }
    if (enabled && !_wasEnabled) {
      _resize(terminal.viewWidth, terminal.viewHeight, 0, 0);
    }
    _wasEnabled = enabled;
    final notice = widget.view.gone
        ? '这个终端已不在电脑上，请新建终端'
        : widget.view.info.isClosed
        ? '终端已结束'
        : !widget.controller.isOnline
        ? '电脑未连接，恢复后会自动同步'
        : !widget.view.loaded
        ? (widget.subscribeError ?? '正在同步终端…')
        : null;
    return Column(
      children: <Widget>[
        if (notice != null) _notice(notice),
        if (_error != null) _notice(_error!),
        for (final event in widget.view.events.whereType<ErrorEvent>())
          _notice(event.text),
        Expanded(
          child: TerminalView(
            terminal,
            key: ObjectKey(terminal),
            readOnly: !enabled,
            deleteDetection: true,
            textStyle: const TerminalStyle(fontSize: 13),
            padding: const EdgeInsets.all(8),
          ),
        ),
        SafeArea(
          top: false,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: <Widget>[
                for (final key in <(String, String)>[
                  ('Esc', '\x1b'),
                  ('Tab', '\t'),
                  ('Ctrl-C', '\x03'),
                  ('Ctrl-D', '\x04'),
                  ('Ctrl-Z', '\x1a'),
                ])
                  TextButton(
                    onPressed: enabled ? () => _input(key.$2) : null,
                    child: Text(key.$1),
                  ),
                for (final key in <(String, TerminalKey)>[
                  ('←', TerminalKey.arrowLeft),
                  ('↑', TerminalKey.arrowUp),
                  ('↓', TerminalKey.arrowDown),
                  ('→', TerminalKey.arrowRight),
                  ('回车', TerminalKey.enter),
                ])
                  TextButton(
                    onPressed: enabled ? () => terminal.keyInput(key.$2) : null,
                    child: Text(key.$1),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _notice(String text) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    color: Theme.of(context).colorScheme.secondaryContainer,
    child: Text(text),
  );
}
