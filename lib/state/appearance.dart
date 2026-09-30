import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'app_store.dart';

/// Theme mode and seed colour, persisted in [AppStore].
class Appearance extends ChangeNotifier {
  Appearance(this._store)
      : _themeMode = _parseMode(_store.getString('themeMode')),
        _seedColor = _parseSeed(_store.getString('seedColor'));

  final AppStore _store;
  ThemeMode _themeMode;
  Color _seedColor;

  ThemeMode get themeMode => _themeMode;
  Color get seedColor => _seedColor;

  set themeMode(ThemeMode value) {
    if (_themeMode == value) return;
    _themeMode = value;
    unawaited(_store.setString('themeMode', value.name));
    notifyListeners();
  }

  set seedColor(Color value) {
    if (_seedColor == value) return;
    _seedColor = value;
    unawaited(_store.setString('seedColor', value.toARGB32().toRadixString(16)));
    notifyListeners();
  }

  static ThemeMode _parseMode(String? raw) {
    for (final mode in ThemeMode.values) {
      if (mode.name == raw) return mode;
    }
    return ThemeMode.system;
  }

  static Color _parseSeed(String? raw) {
    final value = raw == null ? null : int.tryParse(raw, radix: 16);
    return value == null ? AppTheme.seeds.first.color : Color(value);
  }
}
