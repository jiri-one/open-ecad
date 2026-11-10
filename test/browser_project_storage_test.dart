// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/services/project_persistence.dart';
import 'package:open_ecad/services/project_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

String _record(String id, String token) => jsonEncode({
  'version': 2,
  'sessionId': id,
  'storageToken': token,
  'name': 'Browser project',
  'revision': 0,
  'savedRevision': 0,
  'project':
      EcadProject(
        id: 'project',
        name: 'Browser project',
        pages: [Sheet(id: 'sheet', name: 'Sheet', number: '1')],
      ).toJson(),
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'browser locks preserve typed conflicts for simultaneous stale writers',
    () async {
      final first = createProjectStorage(), second = createProjectStorage();
      final original = 'a' * 64, left = 'b' * 64, right = 'c' * 64;
      await first.write(
        'shared',
        _record('shared', original),
        expectedToken: null,
      );
      final saving = first.write(
        'shared',
        _record('shared', left),
        expectedToken: original,
      );
      final stale = second
          .write('shared', _record('shared', right), expectedToken: original)
          .then<Object?>((_) => null, onError: (Object error) => error);
      await saving;
      expect(await stale, isA<ProjectStorageConflict>());
      expect(jsonDecode((await second.read('shared'))!)['storageToken'], left);
    },
    skip: !kIsWeb,
  );

  test(
    'browser project discovery survives an incomplete cached index',
    () async {
      final storage = createProjectStorage();
      await storage.write(
        'first',
        _record('first', 'a' * 64),
        expectedToken: null,
      );
      await storage.write(
        'second',
        _record('second', 'b' * 64),
        expectedToken: null,
      );
      final preferences = await SharedPreferences.getInstance();
      await preferences.setStringList(ProjectPersistence.recoveryIndexKey, [
        'second',
      ]);
      expect(await storage.list(), containsAll(['first', 'second']));
      expect(await storage.list(), hasLength(2));
    },
    skip: !kIsWeb,
  );

  test('browser deletion cannot discard a newer checkpoint', () async {
    final storage = createProjectStorage();
    final before = 'a' * 64, after = 'b' * 64;
    await storage.write(
      'shared',
      _record('shared', before),
      expectedToken: null,
    );
    await storage.write(
      'shared',
      _record('shared', after),
      expectedToken: before,
    );
    await expectLater(
      storage.remove('shared', expectedToken: before),
      throwsA(isA<ProjectStorageConflict>()),
    );
    expect(jsonDecode((await storage.read('shared'))!)['storageToken'], after);
    await storage.remove('shared', expectedToken: after);
    expect(await storage.list(), isEmpty);
  }, skip: !kIsWeb);
}
