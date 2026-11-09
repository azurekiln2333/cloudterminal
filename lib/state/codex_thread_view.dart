import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/protocol.dart';
import 'remote_controller.dart';

/// A selected desktop transcript. Pages are chronological; the cursor fetches
/// earlier turns. Only this view refreshes when a desktop turn changes.
class CodexThreadView extends ChangeNotifier {
  CodexThreadView(this.controller, this.thread) {
    controller.addListener(_connectionChanged);
    _notices = controller.codexNotices.listen((notice) {
      if (notice.threadId == null || notice.threadId == thread.id) {
        unawaited(load(refresh: true));
      }
    });
    _poll = Timer.periodic(const Duration(seconds: 3), (_) {
      if (_ready) unawaited(load(refresh: true));
    });
    _connectionChanged();
  }

  final RemoteController controller;
  CodexThread thread;
  final List<CodexTurn> turns = <CodexTurn>[];
  List<CodexPendingRequest> pendingRequests = <CodexPendingRequest>[];
  String? nextCursor;
  String? error;
  bool loading = false;
  bool loaded = false;
  bool _ready = false;
  bool _fresh = false;
  bool _disposed = false;
  bool _refreshAgain = false;
  int _generation = 0;
  late final StreamSubscription<CodexNotice> _notices;
  late final Timer _poll;

  bool get canControl =>
      _ready &&
      _fresh &&
      loaded &&
      error == null &&
      controller.agent?.codex?.canControl == true;
  bool get canSend => canControl && thread.canAcceptDirectInput;
  bool get canResume => canControl && thread.canResume;

  void _connectionChanged() {
    final ready =
        controller.isOnline && controller.agent?.codex?.available == true;
    if (ready == _ready) return;
    _ready = ready;
    _generation++;
    _fresh = false;
    loading = false;
    _refreshAgain = false;
    if (ready) unawaited(load(refresh: true));
    _notify();
  }

  Future<void> load({bool refresh = false}) async {
    if (!_ready || _disposed) return;
    if (loading) {
      _refreshAgain = _refreshAgain || refresh;
      return;
    }
    if (loaded && !refresh && nextCursor == null) return;
    final generation = _generation;
    final cursor = refresh ? null : nextCursor;
    loading = true;
    error = null;
    _notify();
    try {
      final page = await controller.codexRead(thread.id, cursor: cursor);
      if (_disposed || generation != _generation) return;
      thread = page.thread;
      _fresh = true;
      pendingRequests = page.pendingRequests;
      final freshIds = page.turns.map((turn) => turn.id).toSet();
      final retained = turns
          .where((turn) => !freshIds.contains(turn.id))
          .toList();
      turns
        ..clear()
        ..addAll(
          refresh
              ? <CodexTurn>[...retained, ...page.turns]
              : <CodexTurn>[...page.turns, ...retained],
        );
      // Keep the oldest cursor when refreshing an already paged transcript.
      if (!loaded || !refresh) {
        nextCursor = page.nextCursor == cursor ? null : page.nextCursor;
      }
      loaded = true;
    } on RemoteException catch (e) {
      if (!_disposed && generation == _generation) error = e.message;
    } finally {
      if (!_disposed && generation == _generation) {
        loading = false;
        _notify();
        if (_refreshAgain) {
          _refreshAgain = false;
          unawaited(load(refresh: true));
        }
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
    _poll.cancel();
    unawaited(_notices.cancel());
    controller.removeListener(_connectionChanged);
    super.dispose();
  }
}
