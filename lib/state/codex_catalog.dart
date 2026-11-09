import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/protocol.dart';
import 'remote_controller.dart';

class CodexThreadList {
  final List<CodexThread> items = <CodexThread>[];
  String? nextCursor;
  String? error;
  bool loading = false;
  bool loaded = false;
}

/// Lazy desktop catalog pages. Streaming managed sessions do not reload it.
class CodexCatalog extends ChangeNotifier {
  CodexCatalog(this.controller) {
    controller.addListener(_connectionChanged);
    _connectionChanged();
  }
  final RemoteController controller;
  final List<CodexProject> projects = <CodexProject>[];
  final Map<String?, CodexThreadList> _threads = <String?, CodexThreadList>{};
  String? nextCursor;
  String? error;
  bool loading = false;
  bool loaded = false;
  bool _ready = false;
  bool _disposed = false;
  int _generation = 0;

  CodexThreadList threads(String? projectId) =>
      _threads.putIfAbsent(projectId, CodexThreadList.new);

  void _connectionChanged() {
    final ready =
        controller.isOnline && controller.agent?.codex?.available == true;
    if (ready == _ready) return;
    _ready = ready;
    _generation++;
    loading = false;
    for (final list in _threads.values) {
      list.loading = false;
    }
    if (ready) {
      unawaited(loadProjects(refresh: true));
      for (final entry in _threads.entries) {
        unawaited(loadThreads(entry.key, refresh: true));
      }
    }
    _notify();
  }

  Future<void> loadProjects({bool refresh = false}) async {
    if (loading ||
        !_ready ||
        _disposed ||
        (loaded && !refresh && nextCursor == null)) {
      return;
    }
    final generation = _generation;
    final cursor = refresh ? null : nextCursor;
    loading = true;
    error = null;
    _notify();
    try {
      final page = await controller.codexProjects(cursor: cursor);
      if (_disposed || generation != _generation) return;
      if (refresh) projects.clear();
      final byId = <String, CodexProject>{for (final p in projects) p.id: p};
      for (final p in page.items) {
        byId[p.id] = p;
      }
      projects
        ..clear()
        ..addAll(byId.values);
      nextCursor = page.nextCursor == cursor ? null : page.nextCursor;
      loaded = true;
    } on RemoteException catch (e) {
      if (!_disposed && generation == _generation) error = e.message;
    } finally {
      if (!_disposed && generation == _generation) {
        loading = false;
        _notify();
      }
    }
  }

  Future<void> loadThreads(String? projectId, {bool refresh = false}) async {
    final list = threads(projectId);
    if (list.loading ||
        !_ready ||
        _disposed ||
        (list.loaded && !refresh && list.nextCursor == null)) {
      return;
    }
    final generation = _generation;
    final cursor = refresh ? null : list.nextCursor;
    list.loading = true;
    list.error = null;
    _notify();
    try {
      final page = await controller.codexThreads(
        projectId: projectId,
        cursor: cursor,
      );
      if (_disposed || generation != _generation) return;
      if (refresh) list.items.clear();
      final byId = <String, CodexThread>{for (final t in list.items) t.id: t};
      for (final t in page.items) {
        byId[t.id] = t;
      }
      list.items
        ..clear()
        ..addAll(byId.values);
      list.nextCursor = page.nextCursor == cursor ? null : page.nextCursor;
      list.loaded = true;
    } on RemoteException catch (e) {
      if (!_disposed && generation == _generation) list.error = e.message;
    } finally {
      if (!_disposed && generation == _generation) {
        list.loading = false;
        _notify();
      }
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    controller.removeListener(_connectionChanged);
    super.dispose();
  }
}
