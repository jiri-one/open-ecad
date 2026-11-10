// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

import 'project_storage.dart';

ProjectStorage createProjectStorage() => PreferencesProjectStorage();

class PreferencesProjectStorage implements ProjectStorage {
  static const indexKey = 'open_ecad.recovery.v1.index';
  static const prefix = 'open_ecad.recovery.v1.';
  static Future<void> _writes = Future.value();

  Future<void> _serialize(Future<void> Function() action) {
    final next = _writes.then((_) => action());
    _writes = next.catchError((Object _) {});
    return next;
  }

  Future<SharedPreferences> _freshPreferences() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.reload();
    return preferences;
  }

  List<String> _ids(SharedPreferences preferences) {
    final ids =
        preferences
            .getKeys()
            .where((key) => key.startsWith(prefix) && key != indexKey)
            .where((key) => preferences.get(key) is String)
            .map((key) => key.substring(prefix.length))
            .where((id) => RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(id))
            .toSet();
    final order = preferences.get(indexKey);
    return [
      if (order is List) ...order.whereType<String>().where(ids.remove),
      ...ids,
    ];
  }

  Future<void> _rememberOrder(
    SharedPreferences preferences,
    List<String> ids,
  ) async {
    try {
      await preferences.setStringList(indexKey, ids);
    } catch (_) {
      // Record keys remain discoverable when this optional ordering hint fails.
    }
  }

  @override
  Future<void> write(
    String id,
    String source, {
    required String? expectedToken,
    Uint8List? bytes,
  }) => _serialize(() async {
    validateProjectStorageId(id);
    final preferences = await _freshPreferences();
    if (projectStorageToken(preferences.getString('$prefix$id')) !=
        expectedToken) {
      throw ProjectStorageConflict(id);
    }
    if (!await preferences.setString('$prefix$id', source)) {
      throw StateError('Projekt se nepodařilo uložit.');
    }
    await _rememberOrder(
      preferences,
      <String>{id, ..._ids(preferences)}.toList(),
    );
  });

  @override
  Future<String?> read(String id) async {
    validateProjectStorageId(id);
    return (await _freshPreferences()).getString('$prefix$id');
  }

  @override
  Future<String?> readHeader(String id) async {
    final source = await read(id);
    return source == null ? null : projectStorageHeader(source);
  }

  @override
  Future<List<String>> list() async => _ids(await _freshPreferences());

  @override
  Future<void> remove(String id, {required String? expectedToken}) =>
      _serialize(() async {
        validateProjectStorageId(id);
        final preferences = await _freshPreferences();
        if (projectStorageToken(preferences.getString('$prefix$id')) !=
            expectedToken) {
          throw ProjectStorageConflict(id);
        }
        if (!await preferences.remove('$prefix$id')) {
          throw StateError('Projekt se nepodařilo odstranit.');
        }
        await _rememberOrder(preferences, _ids(preferences));
      });
}
