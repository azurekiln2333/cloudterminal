# Vendored xterm.dart 4.0.0

Source: https://pub.dev/packages/xterm/versions/4.0.0
Upstream: https://github.com/TerminalStudio/xterm.dart
License: MIT, retained in LICENSE.

Only lib/, pubspec.yaml, LICENSE and CHANGELOG.md are copied. The only source
patch is lib/src/ui/shortcut/shortcuts.dart: Apple platforms keep their shortcuts,
all other platforms use the default shortcuts. This handles the extra
TargetPlatform.ohos enum in this project's Flutter SDK while retaining support
for upstream Flutter. Release 3.5.0 also fails on newer KeyEvent APIs.

App tests exercise terminal parsing, replay, input, widgets and the real Node
PTY. Vendor lint exclusion avoids applying application formatting rules to
upstream source. Revisit this patch when upgrading xterm; do not edit the global
Pub cache.
