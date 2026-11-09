import 'dart:async';

import 'package:flutter/material.dart';

import '../models/herdr.dart';
import '../state/herdr_controller.dart';
import '../state/remote_controller.dart';
import '../widgets/herdr_terminal.dart';
import '../widgets/herdr_terminal_rows.dart';

/// A Herdr pane, full screen, typed into directly.
///
/// This screen exists so a pane can be opened **without a local PTY**. The pane
/// lives on the desktop; the app only streams its rendered screen and sends
/// keystrokes through the Herdr API, so creating a terminal session on the PC just
/// to reach a pane would spawn a process nobody asked for. Nothing here touches
/// `RemoteController.createTerminal` or a `SessionView`.
///
/// The screen owns the subscription lifecycle: it selects [paneId] as the user's
/// choice on open (so a later visit and the session screen's rows agree), keeps the
/// watchdog running so the tab/pane rows stay current while it is shown, and stops
/// streaming on close while keeping that choice.
class HerdrTerminalScreen extends StatefulWidget {
  const HerdrTerminalScreen({
    super.key,
    required this.controller,
    required this.herdr,
    required this.paneId,
    this.navigationButton,
  });

  final RemoteController controller;
  final HerdrController herdr;

  /// The pane to open with. Once open, the screen follows
  /// [HerdrController.watchedPaneId] instead, so the tab/pane rows above the
  /// terminal can switch panes without leaving and re-entering the screen.
  final String paneId;

  final Widget? navigationButton;

  @override
  State<HerdrTerminalScreen> createState() => _HerdrTerminalScreenState();
}

class _HerdrTerminalScreenState extends State<HerdrTerminalScreen> {
  @override
  void initState() {
    super.initState();
    // The tab/pane rows are drawn here, so desktop-side structure changes have to
    // reach them: the push stream supplies the edges and this tick is the
    // correctness fallback. Reference-counted, so it dies with the last screen.
    widget.herdr.watch();
    // Explicit: the user asked for this pane, so the desktop's focus must not
    // override it and reopening the screen returns here instead of falling back.
    //
    // Deferred to after the frame: `watchPane` notifies synchronously when the
    // watched/preferred pane actually changes, and notifying an ancestor that is
    // mid-build throws. The screen is mounted by then, so nothing changes for the
    // user except that the first frame renders [HerdrTerminalScreen.paneId] (via
    // [_paneId]'s fallback) until this lands — the same pane.
    //
    // The rows' push stream is what makes this the correctness-critical call: the
    // terminal must be bound to the new pane before it accepts input, which is why
    // the notification is synchronous in the first place.
    //
    // `refresh()` can also notify synchronously, and is the probe that turns
    // `canControl` on (input is gated on it), so skipping it would leave the pane
    // silently untypable when the screen is opened before the first probe.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.herdr.watchPane(widget.paneId, explicit: true);
      unawaited(widget.herdr.refresh());
      // The app bar names the pane and the rows list its tabs, which needs the
      // owning workspace's listing.
      final workspaceId = HerdrController.workspaceOfPaneId(widget.paneId);
      if (workspaceId != null) {
        unawaited(widget.herdr.loadWorkspace(workspaceId));
      }
    });
  }

  @override
  void dispose() {
    widget.herdr.unwatch();
    // Stop reading the pane for a screen nobody is on, but remember the choice so
    // reopening lands here again.
    widget.herdr.suspendWatching();
    super.dispose();
  }

  /// The pane the rows currently point at, falling back to the one opened with.
  ///
  /// The rows switch panes by calling `watchPane(id, explicit: true)`, so
  /// `watchedPaneId` *is* the selection. Reading it every build is what stops this
  /// screen from being pinned to [HerdrTerminalScreen.paneId] forever.
  String get _paneId => widget.herdr.watchedPaneId ?? widget.paneId;

  /// The pane this id names, when the listing has been loaded.
  HerdrPane? _pane(HerdrController herdr, String paneId) {
    final workspaceId = HerdrController.workspaceOfPaneId(paneId);
    if (workspaceId == null) return null;
    for (final pane in herdr.panes(workspaceId)) {
      if (pane.paneId == paneId) return pane;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.herdr,
      builder: (context, _) {
        final paneId = _paneId;
        final pane = _pane(widget.herdr, paneId);
        // `watchedPaneId` goes null only when the selection stopped being streamed:
        // the pane was closed on the desktop and `_reconcilePreferredPane` cleared
        // it. Saying so beats rendering an empty screen forever.
        final gone = widget.herdr.watchedPaneId == null;
        return Scaffold(
          // Keep the default inset behaviour: the terminal fills whatever is left
          // of the screen and the emulator refits (and replays) when the keyboard
          // opens.
          appBar: AppBar(
            leading: widget.navigationButton,
            title: _Title(pane: pane, paneId: paneId, herdr: widget.herdr),
          ),
          body: Column(
            children: <Widget>[
              // Every slot keeps its position whether or not it renders anything:
              // a conditional child would shift the terminal's index and rebuild it
              // from scratch, dropping the soft keyboard whenever a pane closed or a
              // notice appeared.
              HerdrTerminalRows(herdr: widget.herdr),
              gone
                  ? const _NoticeStrip(
                      text: '这个面板已不在电脑上，输入已停止，请返回工作区列表重新选择',
                    )
                  : const SizedBox.shrink(),
              Expanded(
                child: HerdrTerminal(
                  controller: widget.controller,
                  herdr: widget.herdr,
                  paneId: paneId,
                  // A pane removed from an authoritative listing can only fail
                  // every write, so input is switched off instead of sending into a
                  // dead id. A *cold* cache never lands here: the selection is only
                  // cleared by `_reconcilePreferredPane`, which runs on a complete
                  // listing for the pane's own workspace.
                  enabled: !gone,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Full-width one-line banner.
class _NoticeStrip extends StatelessWidget {
  const _NoticeStrip({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.secondaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Text(
        text,
        style: TextStyle(fontSize: 12, color: scheme.onSecondaryContainer),
      ),
    );
  }
}

/// Pane label plus the workspace/tab it belongs to.
class _Title extends StatelessWidget {
  const _Title({required this.pane, required this.paneId, required this.herdr});

  final HerdrPane? pane;
  final String paneId;
  final HerdrController herdr;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final current = pane;
    final subtitle = <String>[
      if (current != null) _workspaceLabel(current.workspaceId),
      if (current != null) _tabLabel(current.tabId),
      paneId,
    ].where((part) => part.isNotEmpty).join(' · ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          current == null ? paneId : herdrPaneLabel(current),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 2),
        Text(
          subtitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }

  String _workspaceLabel(String workspaceId) {
    for (final workspace in herdr.workspaces) {
      if (workspace.workspaceId == workspaceId) return workspace.displayLabel;
    }
    return workspaceId;
  }

  String _tabLabel(String tabId) {
    final workspaceId = HerdrController.workspaceOfPaneId(tabId);
    if (workspaceId == null) return '';
    for (final tab in herdr.tabs(workspaceId)) {
      if (tab.tabId == tabId) {
        return tab.label.isEmpty ? '标签 ${tab.number}' : tab.label;
      }
    }
    return '';
  }
}
