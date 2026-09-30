import 'dart:convert';

import 'package:flutter/material.dart';

/// Presentation helpers for tool calls, shared by the event list and the
/// permission card.

IconData toolIcon(String name) {
  if (name.startsWith('mcp__')) return Icons.extension_rounded;
  switch (name) {
    case 'Bash':
    case 'PowerShell':
    case 'BashOutput':
      return Icons.terminal_rounded;
    case 'Read':
      return Icons.description_outlined;
    case 'Write':
    case 'Edit':
    case 'MultiEdit':
    case 'NotebookEdit':
      return Icons.edit_document;
    case 'Glob':
    case 'Grep':
      return Icons.search_rounded;
    case 'WebFetch':
    case 'WebSearch':
      return Icons.public_rounded;
    case 'Task':
    case 'Agent':
      return Icons.account_tree_outlined;
    case 'TodoWrite':
      return Icons.checklist_rounded;
    case 'AskUserQuestion':
      return Icons.help_outline_rounded;
    case 'ExitPlanMode':
      return Icons.assignment_turned_in_outlined;
    default:
      return Icons.build_outlined;
  }
}

/// Friendly name for tool headers ("mcp__github__create_issue" → "github · create_issue").
String toolLabel(String name) {
  if (name.startsWith('mcp__')) {
    final parts = name.substring(5).split('__');
    return parts.length >= 2 ? '${parts[0]} · ${parts.sublist(1).join('_')}' : name;
  }
  return name;
}

/// A tool input rendered as monospace text blocks. `diff` lines starting
/// with - / + are coloured by the caller.
class ToolDetail {
  const ToolDetail({this.primary, this.body, this.diff = false});

  /// One-line headline (command, path, URL).
  final String? primary;

  /// Multi-line content (file content, diff, JSON).
  final String? body;
  final bool diff;
}

ToolDetail describeToolInput(String name, Object? input) {
  if (input is! Map) return ToolDetail(body: input == null ? null : '$input');
  String? s(String key) {
    final v = input[key];
    return v is String && v.isNotEmpty ? v : null;
  }

  switch (name) {
    case 'Bash':
    case 'PowerShell':
      return ToolDetail(primary: s('command'), body: s('description'));
    case 'Write':
      return ToolDetail(primary: s('file_path'), body: s('content'));
    case 'Edit':
      final old = s('old_string') ?? '';
      final neu = s('new_string') ?? '';
      return ToolDetail(
        primary: s('file_path'),
        body: <String>[
          for (final l in const LineSplitter().convert(old)) '- $l',
          for (final l in const LineSplitter().convert(neu)) '+ $l',
        ].join('\n'),
        diff: true,
      );
    case 'Read':
      return ToolDetail(primary: s('file_path'));
    case 'WebFetch':
      return ToolDetail(primary: s('url'), body: s('prompt'));
    case 'WebSearch':
      return ToolDetail(primary: s('query'));
    case 'Glob':
    case 'Grep':
      return ToolDetail(primary: s('pattern'), body: s('path'));
    case 'ExitPlanMode':
      return ToolDetail(body: s('plan'));
    case 'Task':
    case 'Agent':
      return ToolDetail(primary: s('description'), body: s('prompt'));
    default:
      return ToolDetail(body: const JsonEncoder.withIndent('  ').convert(input));
  }
}

/// Monospace box with optional diff colouring and a height cap.
class CodeBox extends StatelessWidget {
  const CodeBox({
    super.key,
    required this.text,
    required this.style,
    this.diff = false,
    this.maxHeight = 220,
  });

  final String text;
  final TextStyle style;
  final bool diff;
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final Widget content;
    if (diff) {
      final removed = Colors.red.withValues(alpha: 0.14);
      final added = Colors.green.withValues(alpha: 0.16);
      content = SelectableText.rich(
        TextSpan(
          children: <TextSpan>[
            for (final line in text.split('\n'))
              TextSpan(
                text: '$line\n',
                style: style.copyWith(
                  backgroundColor: line.startsWith('- ')
                      ? removed
                      : line.startsWith('+ ')
                          ? added
                          : null,
                ),
              ),
          ],
        ),
      );
    } else {
      content = SelectableText(text, style: style);
    }
    return Container(
      width: double.infinity,
      constraints: BoxConstraints(maxHeight: maxHeight),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(10),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: content,
      ),
    );
  }
}
