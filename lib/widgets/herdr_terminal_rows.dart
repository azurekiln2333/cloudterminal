import 'dart:async';

import 'package:flutter/material.dart';

import '../models/herdr.dart';
import '../state/herdr_controller.dart';
import '../state/remote_controller.dart' show RemoteException;
import 'herdr_status.dart';

/// Herdr's tab and pane switchers, drawn as two thin rows above the terminal.
///
/// These rows mirror the desktop's focus and steer it through the Herdr API —
/// no screen snapshot is read.
///
/// Renders nothing at all when there is no workspace to describe, so a plain
/// terminal keeps its full height.
class HerdrTerminalRows extends StatefulWidget {
  const HerdrTerminalRows({super.key, required this.herdr});

  final HerdrController herdr;

  @override
  State<HerdrTerminalRows> createState() => _HerdrTerminalRowsState();
}

class _HerdrTerminalRowsState extends State<HerdrTerminalRows> {
  /// The error text the user already dismissed, so the strip does not come back
  /// on every repaint for a failure they have read.
  String? _dismissed;

  @override
  Widget build(BuildContext context) {
    final herdr = widget.herdr;
    // Visibility follows the *listing*, not the write capability: a bridge whose
    // control capability is unprobed still has real tabs and panes to show, and
    // hiding the rows there made the layout jump for no honest reason. Each
    // mutating chip is disabled instead.
    if (herdr.workspaces.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final tabs = herdr.visibleTabs;
    final panes = herdr.visiblePanes;
    final error = herdr.error;
    final showError = error != null && error != _dismissed;
    // Landscape phones have very little height; two rows of chrome must not eat
    // a quarter of the terminal.
    final compact =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    // The tab row is only worth its height when there is a choice to make. The
    // pane row is always shown: it is the visible proof that Herdr was
    // recognised, and on a single-pane tab it is the only way to see which pane
    // the desktop is on.
    return Material(
      color: scheme.surfaceContainerLow,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (showError)
            _ErrorStrip(
              text: error,
              onDismiss: () => setState(() => _dismissed = error),
            ),
          if (tabs.isNotEmpty)
            _TabRow(herdr: herdr, tabs: tabs, compact: compact),
          if (panes.isNotEmpty)
            _PaneRow(herdr: herdr, panes: panes, compact: compact),
        ],
      ),
    );
  }
}

/// One line of tab chips for the selected workspace.
class _TabRow extends StatelessWidget {
  const _TabRow({
    required this.herdr,
    required this.tabs,
    required this.compact,
  });

  final HerdrController herdr;
  final List<HerdrTab> tabs;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return _ChipStrip(
      compact: compact,
      trail: _AddTabButton(herdr: herdr, compact: compact),
      children: <Widget>[
        for (final tab in tabs)
          _SwitcherChip(
            label: tab.label.isEmpty ? '${tab.number}' : tab.label,
            selected: tab.focused,
            status: tab.agentStatus,
            compact: compact,
            busy: herdr.isBusy('tab:${tab.tabId}'),
            enabled: herdr.canControl,
            onTap: () => _select(herdr, tab),
          ),
      ],
    );
  }

  /// Focuses [tab] on the desktop, then points the terminal at a pane of that
  /// tab.
  ///
  /// Without the second half the rows contradicted the screen: the pane row
  /// listed the new tab's panes while the terminal below still showed the pane
  /// of the previous tab, so a tab switch looked like it did nothing.
  static Future<void> _select(HerdrController herdr, HerdrTab tab) async {
    try {
      await herdr.focusTab(tab.tabId);
    } on RemoteException {
      // `run` already published the reason through `herdr.error`, which the
      // strip above renders; the selection stays where it was.
      return;
    }
    final candidates = herdr
        .panes(tab.workspaceId)
        .where((pane) => pane.tabId == tab.tabId)
        .toList();
    if (candidates.isEmpty) return;
    final target = candidates.firstWhere(
      (pane) => pane.focused,
      orElse: () => candidates.first,
    );
    herdr.watchPane(target.paneId, explicit: true);
  }
}

/// Right-aligned "new tab" control for the tab row.
///
/// Kept outside the scrolling chip list so it stays reachable no matter how
/// many tabs there are — the whole point of a trailing action.
class _AddTabButton extends StatelessWidget {
  const _AddTabButton({required this.herdr, required this.compact});

  final HerdrController herdr;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final busy = herdr.isBusy('tab-create:${herdr.selectedWorkspaceId}');
    return SizedBox(
      width: compact ? 30 : 34,
      height: compact ? 30 : 34,
      child: IconButton(
        tooltip: '新建标签页',
        padding: EdgeInsets.zero,
        iconSize: compact ? 16 : 18,
        icon: const Icon(Icons.add_rounded),
        color: scheme.primary,
        // Disabled while a create is in flight: Herdr would otherwise make a
        // second tab from a double tap, and the button gives no other feedback.
        onPressed: herdr.canControl && !busy ? herdr.createTab : null,
      ),
    );
  }
}

/// One line of pane chips for the focused tab.
class _PaneRow extends StatelessWidget {
  const _PaneRow({
    required this.herdr,
    required this.panes,
    required this.compact,
  });

  final HerdrController herdr;
  final List<HerdrPane> panes;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return _ChipStrip(
      compact: compact,
      children: <Widget>[
        for (final pane in panes)
          _SwitcherChip(
            label: _paneLabel(pane),
            selected: pane.focused,
            status: pane.agentStatus,
            compact: compact,
            busy: herdr.isBusy('pane:${pane.paneId}'),
            enabled: herdr.canControl,
            onTap: () => _select(herdr, pane),
          ),
      ],
    );
  }

  /// Points the terminal at [pane] and asks the desktop to focus it.
  ///
  /// The local switch happens first: the phone must show the tapped pane even if
  /// the desktop focus action fails or is slow, so the stream follows the local
  /// choice rather than the desktop's reply. Marking the choice as explicit stops
  /// the screen from re-following the desktop's focus afterwards.
  static void _select(HerdrController herdr, HerdrPane pane) {
    herdr.watchPane(pane.paneId, explicit: true);
    // The local switch already happened; a failed desktop focus is published by
    // `run` through `herdr.error` and must not become an unhandled async error.
    unawaited(herdr.focusPane(pane.paneId).then((_) {}, onError: (Object _) {}));
  }

  /// Prefers the user-given pane name, then the terminal title (which Herdr
  /// strips to `π - project` for agent panes), then the raw id.
  static String _paneLabel(HerdrPane pane) {
    for (final candidate in <String?>[
      pane.name,
      pane.terminalTitle,
      pane.cwd.isNotEmpty ? _basename(pane.cwd) : null,
    ]) {
      final text = candidate?.trim();
      if (text != null && text.isNotEmpty) return text;
    }
    return pane.paneId;
  }

  static String _basename(String path) {
    final parts = path.split(RegExp(r'[\\/]'))
      ..removeWhere((part) => part.isEmpty);
    return parts.isEmpty ? path : parts.last;
  }
}

/// A horizontally scrolling single-line strip of chips, with an optional
/// trailing control that stays pinned outside the scroll area.
class _ChipStrip extends StatelessWidget {
  const _ChipStrip({
    required this.children,
    required this.compact,
    this.trail,
  });

  final List<Widget> children;
  final bool compact;
  final Widget? trail;

  @override
  Widget build(BuildContext context) => SizedBox(
    // 44 px on a portrait phone: a 28 px chip inside a 38 px strip needed
    // surgical aim with a thumb, which is how the wrong pane got selected.
    height: compact ? 38 : 44,
    child: Row(
      children: <Widget>[
        Expanded(
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.symmetric(
              horizontal: 8,
              vertical: compact ? 4 : 5,
            ),
            children: <Widget>[
              for (final child in children)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: child,
                ),
            ],
          ),
        ),
        if (trail != null)
          Padding(
            padding: const EdgeInsets.only(left: 2, right: 6),
            child: trail,
          ),
      ],
    ),
  );
}

/// A compact chip: agent-status dot + label, highlighted when focused.
class _SwitcherChip extends StatelessWidget {
  const _SwitcherChip({
    required this.label,
    required this.selected,
    required this.status,
    required this.busy,
    required this.enabled,
    required this.compact,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final HerdrAgentStatus? status;
  final bool busy;
  final bool enabled;
  final bool compact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Selection is drawn explicitly rather than left to `RawChip.selected`:
    // that flag resolves through `ChipTheme.selectedColor`, which this app's
    // theme never defines, so a focused tab and an idle one looked identical.
    final background = selected
        ? scheme.primaryContainer
        : scheme.surfaceContainerHighest;
    final foreground = selected
        ? scheme.onPrimaryContainer
        : scheme.onSurfaceVariant;
    return ConstrainedBox(
      // A thumb-sized target. `shrinkWrap` alone left ~28 px, and `padded`
      // would have overlapped the neighbouring chip's tap area instead.
      constraints: BoxConstraints(minHeight: compact ? 28 : 34),
      child: RawChip(
        onPressed: enabled && !busy ? onTap : null,
        selected: selected,
        showCheckmark: false,
        backgroundColor: background,
        selectedColor: background,
        side: BorderSide(
          color: selected ? scheme.primary : Colors.transparent,
          width: 1.5,
        ),
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        labelPadding: const EdgeInsets.symmetric(horizontal: 4),
        avatar: status == null
            ? null
            : CircleAvatar(
                radius: 4,
                backgroundColor: herdrStatusColor(scheme, status!),
              ),
        label: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 160),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: compact ? 12 : 13,
              color: foreground,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
            ),
          ),
        ),
      ),
    );
  }
}

/// One-line, dismissible failure notice for a failed focus action.
///
/// Two lines, because a Herdr failure ("herdr pane focus wJ:p2: pane not
/// found") is a sentence: clipping it to one ellipsised line left the user with
/// a red bar and no reason.
class _ErrorStrip extends StatelessWidget {
  const _ErrorStrip({required this.text, required this.onDismiss});

  final String text;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 4, 2, 4),
      color: scheme.errorContainer,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(
                text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.3,
                  color: scheme.onErrorContainer,
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: '关闭提示',
            iconSize: 16,
            visualDensity: VisualDensity.compact,
            color: scheme.onErrorContainer,
            onPressed: onDismiss,
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      ),
    );
  }
}
