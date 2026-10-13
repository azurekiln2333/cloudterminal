import 'package:cloudterminal/widgets/herdr_pane_viewport.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Real `pane read` output captured from this machine, hard-wrapped at the
/// desktop pane's ~76 columns. This is the exact shape that looked shattered on
/// the phone before the viewport existed.
const _realDesktopScreen = '''
── ⠴ Working ─────────────────────────────────────────────────────────────

──────────────────────────────────────────────────────────────────────────
D:\\MyNewProjects\\cloudterminal (codex/general-terminal)
↓18k 0.1%/256k (auto)                                  deepseek-v4.1-flash
''';

void main() {
  testWidgets('real desktop-width output reflows to the phone', (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: HerdrPaneViewport(
            outputKey: 'wJ:p2#1',
            text: _realDesktopScreen,
          ),
        ),
      ),
    );

    final state = tester.state<HerdrPaneViewportState>(
      find.byType(HerdrPaneViewport),
    );

    // ignore: avoid_print
    print('=== phone columns: ${state.debugCols} (desktop was ~76) ===');
    // ignore: avoid_print
    print(state.debugBufferText);

    final buffer = state.debugBufferText;
    expect(buffer, contains('deepseek-v4.1-flash'));
    expect(buffer, contains('codex/general-terminal'));
    // The reflow happened: the phone grid is narrower than the desktop's 76.
    expect(state.debugCols, lessThan(76));
    expect(tester.takeException(), isNull);
    expect(find.byType(Scrollable), findsWidgets);
  });
}
