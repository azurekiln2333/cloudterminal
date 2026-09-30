import 'package:flutter/material.dart';

import '../state/appearance.dart';
import '../theme/app_theme.dart';
import 'section_label.dart';

/// Theme mode and seed colour.
Future<void> showAppearanceSheet(BuildContext context, Appearance appearance) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => ListenableBuilder(
      listenable: appearance,
      builder: (context, _) => _AppearanceSheet(appearance: appearance),
    ),
  );
}

class _AppearanceSheet extends StatelessWidget {
  const _AppearanceSheet({required this.appearance});

  final Appearance appearance;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('外观', style: theme.textTheme.titleLarge),
            const SizedBox(height: 18),
            const SectionLabel('主题模式'),
            const SizedBox(height: 8),
            SegmentedButton<ThemeMode>(
              showSelectedIcon: false,
              segments: const <ButtonSegment<ThemeMode>>[
                ButtonSegment<ThemeMode>(
                  value: ThemeMode.system,
                  label: Text('跟随系统'),
                  icon: Icon(Icons.brightness_auto_rounded, size: 18),
                ),
                ButtonSegment<ThemeMode>(
                  value: ThemeMode.light,
                  label: Text('浅色'),
                  icon: Icon(Icons.light_mode_rounded, size: 18),
                ),
                ButtonSegment<ThemeMode>(
                  value: ThemeMode.dark,
                  label: Text('深色'),
                  icon: Icon(Icons.dark_mode_rounded, size: 18),
                ),
              ],
              selected: <ThemeMode>{appearance.themeMode},
              onSelectionChanged: (selection) =>
                  appearance.themeMode = selection.first,
            ),
            const SizedBox(height: 22),
            const SectionLabel('主题色'),
            const SizedBox(height: 10),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: <Widget>[
                for (final seed in AppTheme.seeds)
                  _SeedSwatch(
                    label: seed.label,
                    color: seed.color,
                    selected: appearance.seedColor == seed.color,
                    onTap: () => appearance.seedColor = seed.color,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SeedSwatch extends StatelessWidget {
  const _SeedSwatch({
    required this.label,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Tooltip(
      message: label,
      child: InkWell(
        borderRadius: BorderRadius.circular(30),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color,
            border: Border.all(
              color: selected ? scheme.onSurface : Colors.transparent,
              width: 3,
            ),
          ),
          child: selected
              ? const Icon(Icons.check_rounded, color: Colors.white, size: 20)
              : null,
        ),
      ),
    );
  }
}
