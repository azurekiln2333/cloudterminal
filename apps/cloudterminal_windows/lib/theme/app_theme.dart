import 'package:flutter/material.dart';

/// Standard Material 3 theme for the Windows connection assistant.
///
/// Uses the same seed/palette family as the phone app so the two clients look
/// like one product, without inventing a bespoke visual system: everything here
/// is `useMaterial3` + `ColorScheme.fromSeed` + stock component shapes.
class AppTheme {
  const AppTheme._();

  /// Material 3 seed colours offered in Settings.
  static const List<(String, Color)> seeds = <(String, Color)>[
    ('靛蓝', Color(0xFF4F46E5)),
    ('青绿', Color(0xFF0F766E)),
    ('琥珀', Color(0xFFB45309)),
    ('玫红', Color(0xFFBE185D)),
    ('石墨', Color(0xFF334155)),
  ];

  static ThemeData light(Color seed) => _build(seed, Brightness.light);

  static ThemeData dark(Color seed) => _build(seed, Brightness.dark);

  static ThemeData _build(Color seed, Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      visualDensity: VisualDensity.standard,
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 2,
        centerTitle: false,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainerLow,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
      ),
      listTileTheme: const ListTileThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(12)),
        ),
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        space: 1,
        thickness: 1,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHighest,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        labelType: NavigationRailLabelType.all,
      ),
    );
  }

  /// Monospace text style for stream/terminal output.
  static TextStyle mono(double size, {Color? color, FontWeight? weight}) =>
      TextStyle(
        fontFamily: 'Consolas',
        fontFamilyFallback: const <String>['Menlo', 'monospace'],
        fontSize: size,
        height: 1.35,
        color: color,
        fontWeight: weight,
      );
}
