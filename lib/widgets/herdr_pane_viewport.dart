import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import '../theme/app_theme.dart';

/// How a Herdr pane's real screen text is laid out on the phone.
enum HerdrViewportMode {
  /// Re-wrap the pane to the phone's own column count (default).
  ///
  /// The desktop pane is ~76 columns wide, so raw text arrives hard-wrapped for
  /// a screen far wider than the phone. The emulator reflows it using real
  /// terminal semantics (a row that was full at the old width is a continuation
  /// line, not a hard newline), which is the only way to get box-drawing borders
  /// and tables back into alignment on a narrow screen.
  fitWidth('适配宽度', '按手机宽度重排，边框和表格保持对齐'),

  /// Keep the desktop's original column count and pan horizontally.
  ///
  /// Nothing is re-wrapped, so the layout is exactly what the PC shows — but it
  /// is wider than the phone and must be moved around.
  rawColumns('原始列宽', '保持电脑上的排版，可左右拖动查看');

  const HerdrViewportMode(this.label, this.hint);

  final String label;
  final String hint;
}

/// Read-only terminal viewport for one Herdr pane.
///
/// Herdr hands us the pane's real screen text, including ANSI escape sequences
/// and the desktop's hard wraps. Rendering that as a [Text] widget cannot work:
/// plain text cannot tell a wrap from a newline, so no amount of client-side
/// string handling restores the layout. This widget feeds the bytes into a real
/// terminal emulator and lets *its* reflow do the re-wrapping.
///
/// Input deliberately does not go through the viewport; the screen's own input
/// bar owns that path.
class HerdrPaneViewport extends StatefulWidget {
  const HerdrPaneViewport({
    super.key,
    required this.outputKey,
    required this.text,
    this.mode = HerdrViewportMode.fitWidth,
    this.sourceColumns,
    this.fontSize = 12,
    this.scrollController,
  });

  /// Identifies one complete pane read.
  ///
  /// A new key means "this is fresh content": the emulator is reset and the text
  /// written once. An unchanged key means nothing is written at all, so a rebuild
  /// can never append a duplicate copy of the same screen. The caller owns the
  /// key because only it knows when a read actually happened — two reads can
  /// return identical text and still be distinct results.
  final String outputKey;

  /// Raw screen text. Never rewritten: trailing whitespace, blank lines, hard
  /// wraps and ANSI sequences are all part of the terminal layout.
  final String text;

  final HerdrViewportMode mode;

  /// The desktop pane's column count. Only consulted in
  /// [HerdrViewportMode.rawColumns]; when null the width is inferred from the
  /// content, and if that also fails the viewport falls back to fitting.
  final int? sourceColumns;

  final double fontSize;

  final ScrollController? scrollController;

  @override
  State<HerdrPaneViewport> createState() => HerdrPaneViewportState();
}

class HerdrPaneViewportState extends State<HerdrPaneViewport> {
  /// Enough rows to hold the largest read the UI offers (1000 lines) plus
  /// scrollback, without letting a stuck stream grow the buffer forever.
  static const int _maxLines = 2000;

  Terminal _terminal = Terminal(maxLines: _maxLines);
  int _cols = 0;
  int _rows = 0;

  @override
  void initState() {
    super.initState();
    // The field initializer runs before `widget` is readable, so the first
    // screen has to be written here. Without this the viewport stays empty until
    // a *later* read arrives.
    _terminal.write(widget.text);
  }

  /// Column count actually in use, for tests.
  @visibleForTesting
  int get debugCols => _cols;

  /// The emulator's screen contents with escapes resolved, for tests.
  ///
  /// Uses the buffer's own text extraction so wrapped lines are joined the way
  /// the emulator actually lays them out.
  @visibleForTesting
  String get debugBufferText => _terminal.buffer.getText().trimRight();

  @override
  void didUpdateWidget(HerdrPaneViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.outputKey == widget.outputKey) return;
    // A new read: discard the old screen entirely rather than writing on top of
    // it. Terminal has no public reset, and swapping the instance is the only
    // way to be sure no stale grid, cursor or alternate-buffer state survives.
    // The current grid is preserved so reflow runs at the phone's width with no
    // intermediate 80-column pass.
    final fresh = Terminal(maxLines: _maxLines)
      ..write(widget.text);
    fresh.resize(_cols < 1 ? 80 : _cols, _rows < 1 ? 24 : _rows, 0, 0);
    _terminal = fresh;
  }

  /// Resize the emulator only when the grid actually changes.
  ///
  /// [Terminal.resize] triggers a full reflow of the scrollback; calling it every
  /// frame would reflow the whole buffer on every rebuild.
  void _applyGrid(int cols, int rows, {bool force = false}) {
    if (cols < 1 || rows < 1) return;
    if (!force && cols == _cols && rows == _rows) return;
    _cols = cols;
    _rows = rows;
    _terminal.resize(cols, rows, 0, 0);
  }

  /// Character cell size for the current font, measured the same way the
  /// terminal paints so the column count matches what actually fits.
  Size _charSize() {
    final style = AppTheme.mono(widget.fontSize);
    final painter = TextPainter(
      text: TextSpan(text: 'M' * 10, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    final width = painter.width / 10;
    final height = painter.height;
    painter.dispose();
    // Guard against a font that fails to measure (width 0 would divide by zero).
    return Size(width <= 0 ? widget.fontSize * 0.6 : width, height);
  }

  /// Largest column count present in the text, used when the desktop pane's own
  /// width is unknown and we must keep its layout.
  int _inferColumns(String text) {
    var longest = 0;
    for (final line in text.split('\n')) {
      // Escapes are not printable; ignore them when measuring.
      final width = line.replaceAll(RegExp('\x1b\\[[0-9;?]*[A-Za-z]'), '').length;
      if (width > longest) longest = width;
    }
    return longest;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textStyle = AppTheme.mono(widget.fontSize, color: scheme.onSurface);
    final terminalStyle = TerminalStyle.fromTextStyle(textStyle);

    return LayoutBuilder(
      builder: (context, constraints) {
        final char = _charSize();
        final usableWidth = constraints.maxWidth;
        final usableHeight = constraints.maxHeight;

        int cols;
        if (widget.mode == HerdrViewportMode.rawColumns) {
          final wide = widget.sourceColumns ?? _inferColumns(widget.text);
          // Falling back to fitting keeps a missing layout from blanking the
          // pane; an unknown desktop width must never block rendering.
          cols = wide >= 20
              ? wide
              : _fittedCols(usableWidth, char.width);
        } else {
          cols = _fittedCols(usableWidth, char.width);
        }
        final rows = (usableHeight / char.height).floor();

        _applyGrid(cols.clamp(20, 500), rows.clamp(4, 300));

        final view = TerminalView(
          _terminal,
          key: ObjectKey(_terminal),
          readOnly: true,
          // We size the grid ourselves: letting the view also resize would fight
          // this widget's reflow-driven column count.
          autoResize: false,
          textStyle: terminalStyle,
          padding: const EdgeInsets.all(8),
          scrollController: widget.scrollController,
        );

        if (widget.mode == HerdrViewportMode.rawColumns) {
          // A pane wider than the phone has to be reachable; nothing here is
          // re-wrapped, so panning is the only way to see the right-hand side.
          return InteractiveViewer(
            constrained: false,
            minScale: 1,
            maxScale: 1,
            boundaryMargin: const EdgeInsets.all(48),
            child: SizedBox(
              width: cols * char.width + 16,
              height: usableHeight.isFinite ? usableHeight : 400,
              child: view,
            ),
          );
        }
        return view;
      },
    );
  }

  int _fittedCols(double width, double charWidth) =>
      (width / charWidth).floor();
}
