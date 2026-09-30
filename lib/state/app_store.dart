import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Credentials for one paired PC.
class Pairing {
  const Pairing({
    required this.relayUrl,
    required this.agentId,
    required this.secret,
    this.name = '',
  });

  factory Pairing.fromJson(Map<String, dynamic> json) => Pairing(
        relayUrl: json['relayUrl'] as String,
        agentId: json['agentId'] as String,
        secret: json['secret'] as String,
        name: json['name'] as String? ?? '',
      );

  final String relayUrl;
  final String agentId;
  final String secret;
  final String name;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'relayUrl': relayUrl,
        'agentId': agentId,
        'secret': secret,
        'name': name,
      };

  Pairing copyWith({String? name}) => Pairing(
        relayUrl: relayUrl,
        agentId: agentId,
        secret: secret,
        name: name ?? this.name,
      );
}

/// Tiny JSON key/value store in the app's private support directory.
///
/// The pairing secret grants control of the PC, so it lives only in app-
/// private storage (not shared preferences exported by backups on some
/// platforms, not external storage).
class AppStore {
  AppStore._(this._file, this._data);

  /// In-memory store for tests and platforms without a writable directory.
  AppStore.memory([Map<String, dynamic>? data])
      : _file = null,
        _data = data ?? <String, dynamic>{};

  static Future<AppStore> open() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}${Platform.pathSeparator}cloudterminal.json');
      var data = <String, dynamic>{};
      if (await file.exists()) {
        try {
          final decoded = jsonDecode(await file.readAsString());
          if (decoded is Map<String, dynamic>) data = decoded;
        } on FormatException {
          // Corrupt file: start fresh rather than refusing to launch.
        }
      }
      return AppStore._(file, data);
    } on MissingPluginException {
      return AppStore.memory();
    } on FileSystemException catch (e) {
      debugPrint('AppStore: falling back to memory: $e');
      return AppStore.memory();
    }
  }

  final File? _file;
  final Map<String, dynamic> _data;

  Pairing? get pairing {
    final raw = _data['pairing'];
    if (raw is! Map<String, dynamic>) return null;
    try {
      return Pairing.fromJson(raw);
    } on TypeError {
      return null;
    }
  }

  Future<void> setPairing(Pairing? value) =>
      _put('pairing', value?.toJson());

  String? getString(String key) => _data[key] as String?;

  Future<void> setString(String key, String? value) => _put(key, value);

  /// Last server address typed on the pair screen (kept after unpairing).
  String? get lastRelayUrl => getString('lastRelayUrl');

  Future<void> _put(String key, Object? value) async {
    if (value == null) {
      _data.remove(key);
    } else {
      _data[key] = value;
    }
    final file = _file;
    if (file == null) return;
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(_data), flush: true);
    await tmp.rename(file.path);
  }
}
