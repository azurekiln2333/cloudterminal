import 'package:cloudterminal/widgets/herdr_pane_viewport.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Hosts the viewport with a fixed size so column counts are deterministic.
Widget host({
  required String text,
  required String key,
  HerdrViewportMode mode = HerdrViewportMode.fitWidth,
  int? sourceColumns,
  double width = 400,
  double height = 600,
  double fontSize = 12,
  ScrollController? controller,
}) => MaterialApp(
  home: Scaffold(
    body: SizedBox(
      width: width,
      height: height,
      child: HerdrPaneViewport(
        outputKey: key,
        text: text,
        mode: mode,
        sourceColumns: sourceColumns,
        fontSize: fontSize,
        scrollController: controller,
      ),
    ),
  ),
);

HerdrPaneViewportState stateOf(WidgetTester tester) =>
    tester.state<HerdrPaneViewportState>(find.byType(HerdrPaneViewport));

void main() {
  group('HerdrPaneViewport', () {
    testWidgets('reflows to the available column count, not the desktop one', (
      tester,
    ) async {
      // A desktop pane wraps at ~76 columns; the phone is far narrower.
      final desktopLine = '─' * 76;
      await tester.pumpWidget(host(text: desktopLine, key: 'k1'));

      final cols = stateOf(tester).debugCols;
      expect(cols, greaterThanOrEqualTo(20));
      expect(cols, lessThan(76), reason: 'must reflow narrower than the desktop');
    });

    testWidgets('a wider viewport fits more columns', (tester) async {
      await tester.pumpWidget(host(text: 'x' * 200, key: 'k1', width: 320));
      final narrow = stateOf(tester).debugCols;

      await tester.pumpWidget(host(text: 'x' * 200, key: 'k1', width: 640));
      final wide = stateOf(tester).debugCols;

      expect(wide, greaterThan(narrow));
    });

    testWidgets('a bigger font fits fewer columns', (tester) async {
      await tester.pumpWidget(host(text: 'x' * 200, key: 'k1', fontSize: 12));
      final small = stateOf(tester).debugCols;

      await tester.pumpWidget(host(text: 'x' * 200, key: 'k1', fontSize: 18));
      final large = stateOf(tester).debugCols;

      expect(large, lessThan(small));
    });

    testWidgets('an unchanged outputKey never duplicates the content', (
      tester,
    ) async {
      // The same rebuild happens constantly (scroll, parent setState). Writing
      // the text again each time would multiply the screen contents.
      await tester.pumpWidget(host(text: 'hello', key: 'k1'));
      await tester.pumpWidget(host(text: 'hello', key: 'k1'));
      await tester.pumpWidget(host(text: 'hello', key: 'k1'));

      expect(stateOf(tester).debugBufferText, 'hello');
    });

    testWidgets('a new outputKey resets and rewrites', (tester) async {
      await tester.pumpWidget(host(text: 'first', key: 'k1'));
      expect(stateOf(tester).debugBufferText, 'first');

      await tester.pumpWidget(host(text: 'second', key: 'k2'));
      expect(stateOf(tester).debugBufferText, 'second');
      expect(stateOf(tester).debugBufferText, isNot(contains('first')));
    });

    testWidgets('identical text under a new key is still rewritten once', (
      tester,
    ) async {
      // Two reads returning the same bytes still mean "fresh screen"; keying off
      // the content alone would show a stale buffer after a refresh.
      await tester.pumpWidget(host(text: 'same', key: 'k1'));
      await tester.pumpWidget(host(text: 'same', key: 'k2'));

      expect(stateOf(tester).debugBufferText, 'same');
    });

    testWidgets('renders ANSI colour instead of leaking the escape sequence', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(text: '\x1b[31mRED\x1b[0m plain', key: 'k1'),
      );

      final rendered = stateOf(tester).debugBufferText;
      expect(rendered, contains('RED'));
      expect(rendered, contains('plain'));
      expect(rendered, isNot(contains('\x1b')));
    });

    testWidgets('keeps box drawing intact when reflowing a wide line', (
      tester,
    ) async {
      // A bordered table is the layout that shatters under naive wrapping.
      const table = '┌────┬────┐\n│ a  │ b  │\n└────┴────┘';
      await tester.pumpWidget(host(text: table, key: 'k1'));

      final rendered = stateOf(tester).debugBufferText;
      expect(rendered, contains('┌'));
      expect(rendered, contains('┴'));
    });

    testWidgets('handles empty, whitespace-only and huge single-line text', (
      tester,
    ) async {
      for (final text in <String>['', '   \n\n  ', 'x' * 6000]) {
        await tester.pumpWidget(host(text: text, key: text));
        expect(tester.takeException(), isNull, reason: 'input: ${text.length} chars');
      }
    });

    testWidgets('rawColumns keeps the desktop width and does not reflow', (
      tester,
    ) async {
      final line = '─' * 76;
      await tester.pumpWidget(
        host(
          text: line,
          key: 'k1',
          mode: HerdrViewportMode.rawColumns,
          sourceColumns: 100,
        ),
      );

      // Wider than the 400px viewport: nothing was re-wrapped to fit.
      expect(stateOf(tester).debugCols, 100);
    });

    testWidgets('rawColumns with no layout data still renders', (tester) async {
      await tester.pumpWidget(
        host(
          text: 'short',
          key: 'k1',
          mode: HerdrViewportMode.rawColumns,
          sourceColumns: null,
        ),
      );

      expect(tester.takeException(), isNull);
      expect(stateOf(tester).debugBufferText, contains('short'));
    });

    testWidgets('fits inside a narrow phone without overflowing', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320 * 3, 640 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HerdrPaneViewport(
              outputKey: 'k1',
              text: '─' * 200,
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
    });
  });
}
