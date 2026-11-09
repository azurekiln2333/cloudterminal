import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../models/herdr.dart';
import '../state/herdr_controller.dart';
import '../state/remote_controller.dart';

/// A failed or dropped outbound write, surfaced to the user.
///
/// `paneId` is the pane the bytes were **captured for**, not the pane that
/// happens to be selected when the failure surfaces. Reporting the target is what
/// makes "your input went nowhere" diagnosable after a pane switch.
class HerdrInputFailure {
  const HerdrInputFailure({required this.paneId, required this.message});

  final String paneId;
  final String message;

  @override
  String toString() => 'HerdrInputFailure($paneId: $message)';
}

/// One queued write: the text plus the pane it was typed for.
class _PendingWrite {
  _PendingWrite(this.paneId, this.data, {this.paste = false});

  /// Captured when the event was created and never rewritten.
  final String paneId;

  /// Whether this write is clipboard text (see [HerdrPaneInput.addText]).
  final bool paste;

  String data;
}

/// Serial, ordered outbound queue for one interactive Herdr pane.
///
/// Three problems this exists to solve, each of which was a real bug when input
/// was sent straight from the widget:
///
///  * **Overlap.** `RemoteController` sends each request immediately and the
///    desktop agent handles them concurrently, so two keystrokes could arrive out
///    of order. Here every write is awaited before the next one starts.
///  * **Drift.** A pane switch between "user pressed Enter" and "the request is
///    built" used to re-read the *current* selection, so a line typed into pane A
///    landed in pane B. Every entry captures its [paneId] at enqueue time and the
///    drain never re-reads it.
///  * **Per-character chatter.** A phone types faster than a request round trip.
///    Consecutive text for the same pane is concatenated while it is still queued,
///    which is byte-for-byte the same stream the PC would have received, and turns a
///    typed word into one request instead of eight. (The desktop bridge now writes
///    input through a short-lived socket request rather than one CLI process per
///    keystroke, but batching still saves the round trips.)
///
/// Not solved, on purpose: nothing here retries. A failed write is reported once
/// through [onFailure] and the rest of the queue is dropped, because the ordered
/// stream is already broken and a silent replay of half-typed input into a pane
/// whose state the user can no longer see is worse than making them retype.
class HerdrPaneInput {
  HerdrPaneInput({
    required this.send,
    this.maxChunk = maxChunkChars,
    this.onFailure,
  });

  /// Largest payload sent in one `herdr_send_text`.
  ///
  /// The desktop bridge caps prompt/input text at 64 KiB characters and rejects
  /// anything longer outright, so a paste has to be split. 8192 is far below that
  /// ceiling: it keeps each request small enough for a phone link and leaves room
  /// for JSON escaping.
  static const int maxChunkChars = 8192;

  /// Wire for one chunk. Must complete before the next chunk is attempted.
  ///
  /// [paste] carries the chunk's clipboard intent to the desktop: a paste is wrapped
  /// by the Bridge in the pane's *real* bracketed-paste mode, which this phone cannot
  /// know (the pane read is a rendered grid with no DECSET state).
  final Future<void> Function(String paneId, String data, {bool paste}) send;

  final int maxChunk;

  /// Called exactly once per failed drain, after the rest of the queue is gone.
  void Function(HerdrInputFailure failure)? onFailure;

  final ListQueue<_PendingWrite> _queue = ListQueue<_PendingWrite>();
  bool _draining = false;
  bool _disposed = false;
  Completer<void>? _settle;

  /// Bumped by [clear] to disown whatever the current drain is still awaiting.
  ///
  /// A write in flight when the link drops may never resolve (the socket is gone
  /// and the request only fails on the 20 s timeout). Without this, `_draining`
  /// would stay true and every keystroke after reconnection would queue forever
  /// behind a future that never completes.
  int _epoch = 0;

  /// How many writes are still queued (the one in flight is not counted).
  int get pending => _queue.length;

  /// Whether a chunk is currently being awaited.
  bool get sending => _draining;

  /// Completes when nothing is queued and nothing is in flight.
  ///
  /// Tests await this instead of a fixed delay; the widget never needs it.
  Future<void> get settled {
    if (!_draining && _queue.isEmpty) return Future<void>.value();
    return (_settle ??= Completer<void>()).future;
  }

  /// Queues [data] for [paneId].
  ///
  /// [data] is sent verbatim. It is *not* trimmed: a leading or trailing space is
  /// part of what the user typed into a shell or a REPL.
  ///
  /// [paste] marks the write as clipboard text. It is captured here and travels with
  /// the event, because the intent belongs to where the text came from — not to the
  /// pane state at delivery time. A paste never merges with typed input (that would
  /// hand keystrokes to the desktop's paste path), and never merges with another
  /// paste (each paste stays one request, so its own boundaries survive).
  void addText(String paneId, String data, {bool paste = false}) {
    if (_disposed || paneId.isEmpty || data.isEmpty) return;
    final tail = _queue.isEmpty ? null : _queue.last;
    if (tail != null &&
        !paste &&
        !tail.paste &&
        tail.paneId == paneId &&
        tail.data.length + data.length <= maxChunk) {
      tail.data = '${tail.data}$data';
    } else {
      _queue.add(_PendingWrite(paneId, data, paste: paste));
    }
    _pump();
  }

  /// Drops everything not yet delivered and returns how many writes were lost.
  ///
  /// Used on disconnect: the link is gone, the agent dropped the subscription, and
  /// those bytes can never be delivered, so keeping them queued would either
  /// replay stale input after reconnection or leak it into a later session. The
  /// write already in flight is abandoned rather than awaited — it is counted by
  /// the caller through [sending].
  int clear() {
    final dropped = _queue.length;
    _queue.clear();
    // Disown the in-flight drain so a post-reconnect keystroke is not blocked
    // behind a request that will never answer.
    _epoch += 1;
    _draining = false;
    _completeIfIdle();
    return dropped;
  }

  void dispose() {
    _disposed = true;
    _queue.clear();
    _completeIfIdle();
    onFailure = null;
  }

  void _pump() {
    if (_draining || _disposed) return;
    _draining = true;
    unawaited(_drain(_epoch));
  }

  Future<void> _drain(int epoch) async {
    try {
      while (_queue.isNotEmpty && !_disposed && epoch == _epoch) {
        final write = _queue.removeFirst();
        HerdrInputFailure? failure;
        for (final chunk in _split(write.data, maxChunk)) {
          try {
            // The intent is per chunk: a long paste is several requests, and every
            // one of them must still be a paste or the desktop would type the tail.
            await send(write.paneId, chunk, paste: write.paste);
          } on RemoteException catch (e) {
            failure = HerdrInputFailure(paneId: write.paneId, message: e.message);
            break;
          } catch (e) {
            failure = HerdrInputFailure(paneId: write.paneId, message: '$e');
            break;
          }
          // A disconnect disowns this drain while the await is outstanding; the
          // chunk is already delivered, the rest must not follow.
          if (_disposed || epoch != _epoch) return;
        }
        // The epoch is checked *before* acting on a failure as well as on success.
        // A write that fails after `clear()` (a disconnect-and-reconnect) belongs to
        // a link that is already gone: clearing the queue here would discard the
        // new link's freshly typed input, and reporting the failure would name a
        // loss the user never had. Nothing about a disowned drain may touch state.
        if (_disposed || epoch != _epoch) return;
        if (failure != null) {
          // Drop the tail: the ordered stream is broken, and it would otherwise
          // replay the user's typing into a pane they have already left.
          _queue.clear();
          onFailure?.call(failure);
          break;
        }
      }
    } finally {
      // A disowned drain must not clear the flag of the drain that replaced it.
      if (epoch == _epoch) {
        _draining = false;
        _completeIfIdle();
      }
    }
  }

  void _completeIfIdle() {
    if (_draining || _queue.isNotEmpty) return;
    final settle = _settle;
    _settle = null;
    if (settle != null && !settle.isCompleted) settle.complete();
  }

  /// Splits [data] into chunks of at most [max] UTF-16 code units.
  ///
  /// A chunk boundary never falls **between the halves of a surrogate pair**: each
  /// chunk is serialised as JSON on the way to the PC, and a lone surrogate cannot
  /// be encoded, so it would arrive as U+FFFD and corrupt an emoji or a rare CJK
  /// character. Escape sequences may be split — the chunks travel over the same
  /// ordered channel and are written into one PTY, so the program still sees the
  /// complete byte stream.
  static List<String> _split(String data, int max) {
    if (max <= 0 || data.length <= max) return <String>[data];
    final chunks = <String>[];
    var start = 0;
    while (start < data.length) {
      var end = start + max;
      if (end >= data.length) end = data.length;
      if (end > start + 1 && _isHighSurrogate(data.codeUnitAt(end - 1))) {
        end -= 1;
      }
      chunks.add(data.substring(start, end));
      start = end;
    }
    return chunks;
  }

  static bool _isHighSurrogate(int unit) => unit >= 0xD800 && unit <= 0xDBFF;
}

/// Intent for a paste requested by a physical keyboard shortcut.
///
/// xterm's own `PasteTextIntent` handler calls `Terminal.paste` directly, which
/// addresses whatever pane is current at that moment. Replacing the shortcut map
/// with these intents routes the physical shortcut through the same guarded path as
/// the on-screen button.
class _PanePasteIntent extends Intent {
  const _PanePasteIntent();
}

/// Intent for a copy requested by a physical keyboard shortcut.
class _PaneCopyIntent extends Intent {
  const _PaneCopyIntent();
}

/// xterm's default shortcuts with copy/paste re-pointed at [_PanePasteIntent] and
/// [_PaneCopyIntent]. Everything else (`Ctrl+A`, and `Ctrl+C` on non-Apple platforms
/// which must stay `^C` for the pane) is left untouched.
Map<ShortcutActivator, Intent> _paneShortcuts() {
  final shortcuts = Map<ShortcutActivator, Intent>.from(
    defaultTerminalShortcuts,
  )..removeWhere(
    (_, intent) =>
        intent is PasteTextIntent || intent is CopySelectionTextIntent,
  );
  final apple =
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.macOS;
  if (apple) {
    shortcuts[const SingleActivator(LogicalKeyboardKey.keyV, meta: true)] =
        const _PanePasteIntent();
    shortcuts[const SingleActivator(LogicalKeyboardKey.keyC, meta: true)] =
        const _PaneCopyIntent();
  } else {
    shortcuts[const SingleActivator(LogicalKeyboardKey.keyV, control: true)] =
        const _PanePasteIntent();
    shortcuts[const SingleActivator(
      LogicalKeyboardKey.keyC,
      control: true,
      shift: true,
    )] =
        const _PaneCopyIntent();
  }
  return shortcuts;
}

/// Interactive screen of one Herdr pane, typed into directly.
///
/// The pane is drawn by replaying the agent's flattened snapshot into an xterm
/// [Terminal] at the **phone's** column count (see [HerdrPaneSnapshot]); input is
/// the reverse direction and goes through xterm's own key encoding:
///
///     keyboard / IME / paste -> Terminal.onOutput(already-encoded bytes)
///       -> HerdrPaneInput (serial, ordered, pane captured) -> herdr_send_text
///
/// Nothing is echoed locally. The bytes the user types are the PC's to interpret
/// and the PC's to draw; showing a guess here would put text on screen that the
/// desktop never accepted.
///
/// No geometry is ever sent to the desktop: the snapshot is a rendered grid, not a
/// PTY, so resizing the emulator to the phone must not resize the pane on the PC.
class HerdrTerminal extends StatefulWidget {
  const HerdrTerminal({
    super.key,
    required this.controller,
    required this.herdr,
    required this.paneId,
    this.enabled = true,
    this.autofocus = false,
  });

  final RemoteController controller;
  final HerdrController herdr;

  /// The pane to display and type into. Changing it keeps the widget (and the
  /// keyboard focus) alive and only re-points the stream.
  final String paneId;

  /// False when the owner knows the pane is gone.
  ///
  /// Typing is then pointless: the desktop would reject every write to a closed
  /// pane. The screen turns input off and shows its own notice, while the last
  /// known screen stays visible and copyable.
  final bool enabled;

  final bool autofocus;

  @override
  State<HerdrTerminal> createState() => _HerdrTerminalState();
}

class _HerdrTerminalState extends State<HerdrTerminal> {
  late final Terminal _terminal = _createTerminal();
  late final FocusNode _focusNode = FocusNode(
    debugLabel: 'herdr-pane:${widget.paneId}',
  );
  late final HerdrPaneInput _input = HerdrPaneInput(
    send: _sendChunk,
    onFailure: _onFailure,
  );

  /// Selection state, shared with [TerminalView].
  ///
  /// Passed in rather than left to the view's internal default so the touch
  /// affordances can see it: long-press and drag select text through this
  /// controller, and the Copy button is enabled exactly while a selection exists.
  /// xterm's own copy action is only wired to a physical Ctrl/Cmd+C shortcut, which
  /// a phone cannot produce.
  final TerminalController _selection = TerminalController();

  /// Owned so a pane switch can jump the view to the new pane's live end, and so
  /// both ends of a long screen stay reachable by scrolling.
  final ScrollController _scroll = ScrollController();

  /// Snapshot text and pane already painted, so an unchanged push does not
  /// repaint. Keyed by pane as well as text: two panes can hold identical screen
  /// text and a switch must still replay.
  String? _paintedText;
  String? _paintedPane;

  /// Last grid the renderer reported; a change in **either** dimension reflows
  /// the buffer and therefore needs a replay.
  int? _gridWidth;
  int? _gridHeight;

  /// True while a snapshot is being written into the emulator.
  ///
  /// A snapshot can contain device queries (`ESC[c`, `ESC[6n`, …) that the
  /// emulator answers by calling [Terminal.onOutput] **synchronously from inside
  /// the write**. Those bytes are the phone replying to itself; forwarding them
  /// would inject DA/DSR replies into the desktop pane on every repaint. The flag
  /// is synchronous-safe precisely because the parser and the reply are both
  /// synchronous.
  bool _replaying = false;

  /// Bumped on every pane change.
  ///
  /// Any action that awaits before it produces terminal input (a clipboard read, in
  /// practice) captures this first and abandons itself if it no longer matches: the
  /// bytes must go to the pane the user was looking at when they acted, and
  /// [widget.paneId] is only the *current* pane.
  int _paneEpoch = 0;

  /// A failure or a dropped-input notice the user must see. Cleared on the next
  /// successful write and on demand.
  String? _notice;

  /// Set once a keystroke was refused while the pane switch was in flight, so the
  /// notice appears once instead of on every key of the transition.
  bool _transitionWarned = false;

  late bool _wasOnline = widget.controller.isOnline;

  bool get _canType =>
      widget.enabled && widget.controller.isOnline && widget.herdr.canControl;

  /// True when the selection has moved but this widget has not been rebuilt yet.
  ///
  /// `watchPane` updates `watchedPaneId` and notifies synchronously, while this
  /// widget's [HerdrTerminal.paneId] only changes when its owner rebuilds. In that
  /// window the emulator still belongs to the old pane, so forwarding its bytes
  /// would type into the pane the user just left. Already-queued writes keep the
  /// pane they were captured for — that ordering contract is untouched; only the
  /// *new* bytes are refused, and the user is told why.
  bool get _paneMovedOn {
    final watched = widget.herdr.watchedPaneId;
    // A null selection is not a move: it means nothing is streamed (the owner
    // disables input for a dead pane through `enabled`), or the owner has not
    // issued its watch yet.
    return watched != null && watched != widget.paneId;
  }

  @override
  void initState() {
    super.initState();
    _terminal.onOutput = _onOutput;
    widget.controller.addListener(_onController);
  }

  @override
  void didUpdateWidget(HerdrTerminal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onController);
      widget.controller.addListener(_onController);
      _wasOnline = widget.controller.isOnline;
    }
    if (oldWidget.paneId != widget.paneId) {
      // Re-point, do not rebuild: keeping the same Terminal and FocusNode is what
      // keeps the soft keyboard up while the user moves between panes. Queued
      // writes keep the pane they were captured for; nothing is retargeted.
      _paneEpoch += 1;
      _paintedText = null;
      _paintedPane = null;
      // The switch this widget was waiting for has landed; a refusal can be
      // reported again for the next one.
      _transitionWarned = false;
      // The previous pane's scroll offset means nothing for the new screen; go to
      // its live end the way opening a terminal normally does.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scroll.hasClients) return;
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      });
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onController);
    _terminal.onOutput = null;
    _terminal.onResize = null;
    _input.dispose();
    _selection.dispose();
    _scroll.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Terminal _createTerminal() {
    final terminal = Terminal(maxLines: 10000);
    // The renderer owns the grid, so it reports every refit here — first layout,
    // rotation, keyboard open/close and window resize. The replay is deferred to
    // after the frame because this fires inside `RenderTerminal.performLayout`
    // and writing there mutates the render object mid-layout.
    terminal.onResize = (width, height, pixelWidth, pixelHeight) {
      if (_gridWidth == width && _gridHeight == height) return;
      _gridWidth = width;
      _gridHeight = height;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        // `Terminal.resize` reflows and can drop rows, so a static snapshot has to
        // be replayed on every refit — including the first one, which is why this
        // cannot wait for a *change* in columns.
        _paintedText = null;
        _paint();
        setState(() {});
      });
    };
    return terminal;
  }

  // ---------------------------------------------------------------------------
  // Outbound input
  // ---------------------------------------------------------------------------

  /// Receives already-encoded terminal bytes from xterm.
  ///
  /// xterm encodes a keystroke against the pane's *current* modes (application
  /// cursor keys, newline mode), which is why the raw bytes are forwarded instead of
  /// a logical key list: Enter is `\r`, Backspace is `\x7f`, an arrow is `ESC[A` or
  /// `ESCOD`, Ctrl-C is `\x03`.
  ///
  /// Clipboard text never comes through here: it is enqueued directly by [_paste]
  /// with its own intent, because wrapping it in bracketed-paste markers is the
  /// desktop's job (it alone knows the pane's real mode).
  void _onOutput(String data) {
    if (_replaying || data.isEmpty) return;
    if (!_canType) return;
    if (_paneMovedOn) {
      _warnPaneTransition();
      return;
    }
    // Typed/keys only, so the IME's own Return is the only thing rewritten.
    _input.addText(widget.paneId, _normaliseReturn(data));
  }

  /// Says once per switch that this keystroke was not sent to the pane it left.
  void _warnPaneTransition() {
    if (!mounted || _transitionWarned) return;
    _transitionWarned = true;
    setState(() => _notice = '面板正在切换，这一步输入没有送出');
  }

  /// Turns the IME's Return into a carriage return.
  ///
  /// A physical Enter goes through xterm's key table and is already `\r`. The soft
  /// keyboard instead inserts a newline *character* through the text-input channel,
  /// and a lone LF depends on the tty's ICRNL to become a submit — in raw mode
  /// (a TUI, `vim`) it does not. A single-LF payload from the IME is unambiguous.
  ///
  /// Only the IME/keyboard path is rewritten: clipboard text is enqueued directly by
  /// [_paste] and keeps its original LF, so a newline-only clipboard stays faithful.
  static String _normaliseReturn(String data) =>
      data == '\n' ? '\r' : data;

  Future<void> _sendChunk(String paneId, String data, {bool paste = false}) async {
    await widget.herdr.sendText(paneId, data, paste: paste);
    if (mounted && _notice != null) setState(() => _notice = null);
  }

  void _onFailure(HerdrInputFailure failure) {
    if (!mounted) return;
    setState(() {
      _notice = '发送到 ${failure.paneId} 失败：${failure.message}（不会自动重发）';
    });
  }

  /// Clears queued input when the link drops.
  ///
  /// The agent drops its watch and the socket is gone, so those bytes cannot be
  /// delivered; queueing them would replay stale typing into whatever session is
  /// connected next. The focus node is deliberately left alone: reconnecting must
  /// not cost the user their keyboard.
  void _onController() {
    final online = widget.controller.isOnline;
    if (_wasOnline && !online) {
      final inFlight = _input.sending;
      final dropped = _input.clear();
      // A clipboard read that is still outstanding belongs to the dead link too: if
      // it survived the reconnect the paste would deliver text the user copied while
      // looking at a different (or since-reconnected) pane.
      _paneEpoch += 1;
      if (mounted && (dropped > 0 || inFlight)) {
        setState(() {
          _notice = '电脑断线，刚才的输入可能没有送达（不会自动重发）';
        });
      }
    }
    _wasOnline = online;
  }

  // ---------------------------------------------------------------------------
  // Rendering
  // ---------------------------------------------------------------------------

  /// Replays the pane's current screen as a complete snapshot.
  ///
  /// The cheap text comparison runs first because deriving a snapshot does the
  /// grid-padding work; this method runs on every controller notification.
  void _paint() {
    final text = widget.herdr.paneText(widget.paneId);
    if (_paintedPane == widget.paneId && _paintedText == text) return;
    _paintedPane = widget.paneId;
    _paintedText = text;
    final snapshot = widget.herdr.paneSnapshot(widget.paneId);
    // A snapshot is the whole screen, so clear first — otherwise the previous
    // frame's tail stays below the new one.
    _terminal.eraseDisplay();
    _terminal.eraseScrollbackOnly();
    _terminal.setCursor(0, 0);
    _replaying = true;
    try {
      _terminal.write(snapshot.replayText);
    } finally {
      _replaying = false;
    }
  }

  /// Sends one logical key through the same encoder the keyboard uses.
  ///
  /// Going through [Terminal.keyInput] rather than a hand-written escape string is
  /// what makes these buttons respect the pane's modes: `⇧Tab` becomes `ESC[Z`,
  /// an arrow becomes `ESCOD` in application cursor mode, and Backspace stays
  /// `\x7f` (not `\b`).
  void _key(TerminalKey key, {bool ctrl = false, bool shift = false}) {
    _terminal.keyInput(key, ctrl: ctrl, shift: shift);
  }

  /// Sends the clipboard as a paste.
  ///
  /// The clipboard text is enqueued **verbatim** with `paste: true`; this phone never
  /// wraps it in bracketed-paste markers and never guesses the pane's paste mode,
  /// because it cannot know it — a Herdr pane read is a rendered grid and carries no
  /// DECSET state. The desktop Bridge is the only side that knows the pane's real
  /// bracketed-paste mode, so it does the wrapping (see [HerdrPaneInput.addText]).
  ///
  /// The clipboard read is asynchronous, so the pane (and the link) can change while
  /// it is outstanding. Both are re-checked before the text is queued: pasting a path
  /// copied for pane A into pane B is exactly the kind of stray input that must not
  /// happen.
  Future<void> _paste() async {
    final epoch = _paneEpoch;
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty || !mounted) return;
    // The link is checked first: a disconnect bumps the epoch as well, and telling
    // the user they "switched panes" when the PC actually went away would be wrong.
    if (!_canType) {
      setState(() => _notice = '电脑未连接或输入已暂停，这次粘贴没有送出');
      return;
    }
    if (epoch != _paneEpoch || _paneMovedOn) {
      setState(() {
        _notice = '已切换到其他面板，这次粘贴没有送出（请在面板里重新粘贴）';
      });
      return;
    }
    // Direct enqueue, not [Terminal.paste]: the clipboard's own boundaries and
    // control characters travel unchanged, and the intent is carried per request.
    // An agent that does not support the flag is refused by the controller, whose
    // error reaches the user through [_onFailure] like any other failed write.
    _input.addText(widget.paneId, text, paste: true);
  }

  /// Copies the current selection to the clipboard.
  ///
  /// The selection lives in the *emulator* (it is a range over the replayed screen),
  /// so copying is entirely local: no bytes are sent to the pane, and the selection
  /// is cleared afterwards the way a desktop terminal does. Haptic feedback is the
  /// only confirmation — a banner would sit in the layout for the next keystroke.
  Future<void> _copy() async {
    final selection = _selection.selection;
    if (selection == null) return;
    final text = _terminal.buffer.getText(selection);
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    _selection.clearSelection();
    await HapticFeedback.selectionClick();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[
        widget.controller,
        widget.herdr,
        // Rebuilds the key row when a long-press selection appears, so Copy turns
        // from disabled to enabled without any other state change.
        _selection,
      ]),
      builder: (context, _) {
        final canType = _canType;
        _paint();
        final status = _statusLine(canType);
        final notice = _notice;
        return Column(
          children: <Widget>[
            // Both banners keep their slot even when absent. A conditionally present
            // child shifts every later child's index, and a shifted [TerminalView] is
            // rebuilt from scratch — which closes its text-input connection and
            // dismisses the keyboard exactly when a notice appears (on a disconnect,
            // say). An empty box costs nothing and keeps the State alive.
            status == null
                ? const SizedBox.shrink()
                : _NoticeStrip(text: status),
            notice == null
                ? const SizedBox.shrink()
                : _NoticeStrip(text: notice, isError: true),
            Expanded(
              // One guarded clipboard path. A physical Ctrl/Cmd+V is remapped to
              // [_PanePasteIntent] (see [_paneShortcuts]) so it cannot reach xterm's
              // own handler, which pastes into whichever pane is current.
              child: Actions(
                actions: <Type, Action<Intent>>{
                  _PanePasteIntent: CallbackAction<_PanePasteIntent>(
                    onInvoke: (_) {
                      unawaited(_paste());
                      return null;
                    },
                  ),
                  _PaneCopyIntent: CallbackAction<_PaneCopyIntent>(
                    onInvoke: (_) {
                      unawaited(_copy());
                      return null;
                    },
                  ),
                },
                child: TerminalView(
                  _terminal,
                  controller: _selection,
                  focusNode: _focusNode,
                  scrollController: _scroll,
                  autofocus: widget.autofocus,
                  shortcuts: _paneShortcuts(),
                  // Input is gated on Herdr, never on a local PTY: the pane lives on
                  // the desktop, so it stays controllable after an agent reload even
                  // though the PTY session this screen started with is gone.
                  readOnly: !canType,
                  // Soft-keyboard backspace arrives as a shorter editing value and
                  // is only distinguishable thanks to this sentinel.
                  deleteDetection: true,
                  textStyle: const TerminalStyle(fontSize: 12),
                ),
              ),
            ),
            _AuxKeyRow(
              enabled: canType,
              canCopy: _selection.selection != null,
              onKey: _key,
              onPaste: _paste,
              onCopy: _copy,
            ),
          ],
        );
      },
    );
  }

  /// One line explaining why input is unavailable, or null when it is fine.
  String? _statusLine(bool canType) {
    if (canType) return null;
    if (!widget.controller.isOnline) return '电脑未连接，输入已暂停';
    if (!widget.herdr.canControl) return 'Herdr 暂不可用，输入已暂停';
    return null;
  }}

/// The row of keys a phone keyboard cannot produce.
///
/// Wrapped in [ExcludeFocus] on purpose: a focusable button would take focus on
/// tap, tear down the terminal's text-input connection and dismiss the soft
/// keyboard, so every Esc/Tab/arrow would cost the user their keyboard. Excluding
/// the row from focus keeps the IME attached to the terminal while these buttons
/// fire.
class _AuxKeyRow extends StatelessWidget {
  const _AuxKeyRow({
    required this.enabled,
    required this.canCopy,
    required this.onKey,
    required this.onPaste,
    required this.onCopy,
  });

  final bool enabled;

  /// True while the emulator holds a selection.
  ///
  /// Copy is a *local* operation, so it is not gated on the link: reading text off
  /// the screen the phone already has must keep working while the PC is offline.
  final bool canCopy;
  final void Function(TerminalKey key, {bool ctrl, bool shift}) onKey;
  final Future<void> Function() onPaste;
  final Future<void> Function() onCopy;

  static const List<(String, TerminalKey)> _plain = <(String, TerminalKey)>[
    ('Esc', TerminalKey.escape),
    ('Tab', TerminalKey.tab),
    ('⌫', TerminalKey.backspace),
    ('←', TerminalKey.arrowLeft),
    ('↑', TerminalKey.arrowUp),
    ('↓', TerminalKey.arrowDown),
    ('→', TerminalKey.arrowRight),
    ('回车', TerminalKey.enter),
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainer,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 36,
          child: ExcludeFocus(
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              children: <Widget>[
                for (final (label, key) in _plain)
                  _key(label, () => onKey(key)),
                _key('⇧Tab', () => onKey(TerminalKey.tab, shift: true)),
                _key('Ctrl-C', () => onKey(TerminalKey.keyC, ctrl: true)),
                _key('Ctrl-D', () => onKey(TerminalKey.keyD, ctrl: true)),
                _key('Ctrl-Z', () => onKey(TerminalKey.keyZ, ctrl: true)),
                _key('复制', onCopy, active: canCopy),
                _key('粘贴', onPaste),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// A compact button. [active] overrides the global [enabled] gate for actions
  /// that do not depend on the link (see [canCopy]).
  Widget _key(String label, VoidCallback onPressed, {bool? active}) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 1),
    child: TextButton(
      // Compact so the whole row fits a phone height budget and scrolls instead
      // of wrapping into a second line.
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 30),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        textStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
      ),
      onPressed: (active ?? enabled) ? onPressed : null,
      child: Text(label),
    ),
  );
}

/// One-line banner for a status reason or a write failure.
class _NoticeStrip extends StatelessWidget {
  const _NoticeStrip({required this.text, this.isError = false});

  final String text;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final background = isError
        ? scheme.errorContainer
        : scheme.secondaryContainer;
    final foreground = isError
        ? scheme.onErrorContainer
        : scheme.onSecondaryContainer;
    return Container(
      width: double.infinity,
      color: background,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      child: Text(
        text,
        style: TextStyle(fontSize: 12, color: foreground),
      ),
    );
  }
}

/// Short label for a pane: its name, else the terminal title, else the id.
///
/// Shared by the pane terminal's app bar so a pane opened straight from the list is
/// identifiable without the workspace rows on screen.
String herdrPaneLabel(HerdrPane pane) {
  for (final candidate in <String?>[
    pane.name,
    pane.terminalTitle,
    pane.cwd.isEmpty ? null : _basename(pane.cwd),
  ]) {
    final text = candidate?.trim();
    if (text != null && text.isNotEmpty) return text;
  }
  return pane.paneId;
}

String _basename(String path) {
  final parts = path.split(RegExp(r'[\\/]'))
    ..removeWhere((part) => part.isEmpty);
  return parts.isEmpty ? path : parts.last;
}
