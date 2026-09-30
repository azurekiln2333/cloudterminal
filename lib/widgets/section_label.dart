import 'package:flutter/material.dart';

/// Small uppercase-style heading used inside sheets and forms.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.4,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}
