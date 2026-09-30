import 'package:flutter/material.dart';

import '../models/protocol.dart';
import '../state/remote_controller.dart';
import '../theme/app_theme.dart';

/// Browse directories on the PC (limited to the agent's --root dirs) and
/// return the chosen path.
Future<String?> showDirPickerSheet(
  BuildContext context,
  RemoteController controller, {
  String? initialPath,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (context) => FractionallySizedBox(
      heightFactor: 0.85,
      child: _DirPicker(controller: controller, initialPath: initialPath),
    ),
  );
}

class _DirPicker extends StatefulWidget {
  const _DirPicker({required this.controller, this.initialPath});

  final RemoteController controller;
  final String? initialPath;

  @override
  State<_DirPicker> createState() => _DirPickerState();
}

class _DirPickerState extends State<_DirPicker> {
  DirListing? _listing;
  String? _error;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load(widget.initialPath);
  }

  Future<void> _load(String? path) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final listing = await widget.controller.listDir(path);
      if (mounted) setState(() => _listing = listing);
    } on RemoteException catch (e) {
      if (!mounted) return;
      // The initial path may be outside the allowed roots: fall back.
      if (path != null && path.isNotEmpty && _listing == null) {
        return _load(null);
      }
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final listing = _listing;

    return SafeArea(
      top: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text('选择工作目录', style: theme.textTheme.titleLarge),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: <Widget>[
                IconButton(
                  tooltip: '上一级',
                  onPressed: listing?.parent == null || _loading
                      ? null
                      : () => _load(listing!.parent),
                  icon: const Icon(Icons.arrow_upward_rounded),
                ),
                Expanded(
                  child: Text(
                    listing == null || listing.isRootList
                        ? '允许访问的目录'
                        : listing.path,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppTheme.mono(12.5, color: scheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          const Divider(),
          Expanded(child: _body(scheme)),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
            child: FilledButton.icon(
              onPressed: listing == null || listing.isRootList
                  ? null
                  : () => Navigator.of(context).pop(listing.path),
              icon: const Icon(Icons.check_rounded),
              label: const Text('使用此目录'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _body(ColorScheme scheme) {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.folder_off_outlined, size: 40, color: scheme.error),
              const SizedBox(height: 12),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () => _load(_listing?.path),
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    final listing = _listing;
    if (listing == null) return const SizedBox.shrink();
    if (listing.entries.isEmpty) {
      return Center(
        child: Text(
          '没有子目录',
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
      );
    }
    return ListView.builder(
      itemCount: listing.entries.length,
      itemBuilder: (context, i) {
        final entry = listing.entries[i];
        return ListTile(
          leading: Icon(
            listing.isRootList ? Icons.storage_rounded : Icons.folder_rounded,
            color: scheme.primary,
          ),
          title: Text(
            entry.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: _loading ? null : () => _load(entry.path),
        );
      },
    );
  }
}
