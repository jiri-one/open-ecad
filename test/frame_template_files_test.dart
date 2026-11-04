// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:convert';

import 'package:ecad_core/ecad_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/services/frame_template_files.dart';

void main() {
  test(
    'imports independent IDs and exports definitions without resolved metadata',
    () async {
      final template = FrameTemplates.builtin;
      String? exported;
      final files = FrameTemplateFiles(
        read: () async => FrameTemplateCodec.encode(template),
        write: (source, name, canCommit) async {
          expect(canCommit(), isTrue);
          expect(name, endsWith('.oecadframe'));
          exported = source;
          return name;
        },
      );
      final a = (await files.importTemplate(canCommit: () => true))!;
      final b = (await files.importTemplate(canCommit: () => true))!;
      expect(a.id, isNot(template.id));
      expect(b.id, isNot(a.id));
      expect(a.copyWith(id: template.id).toJson(), template.toJson());
      await files.exportTemplate(a, canCommit: () => true);
      expect(FrameTemplateCodec.decode(exported!).toJson(), a.toJson());
      expect((jsonDecode(exported!) as Map).keys.toSet(), {
        'format',
        'formatVersion',
        'template',
      });
      expect(exported, contains('{{document.drawnBy}}'));
      expect(exported, isNot(contains('documentFields')));
      expect(exported, isNot(contains('pages')));
    },
  );

  test('cancel and stale import leave no definition to adopt', () async {
    final cancel = FrameTemplateFiles(read: () async => null);
    expect(await cancel.importTemplate(canCommit: () => true), isNull);
    final pending = Completer<String?>();
    var current = true;
    final files = FrameTemplateFiles(read: () => pending.future);
    final result = files.importTemplate(canCommit: () => current);
    current = false;
    pending.complete(FrameTemplateCodec.encode(FrameTemplates.builtin));
    await expectLater(result, throwsFormatException);
  });

  test(
    'rejects malformed or oversized files and stale export before writer',
    () async {
      for (final source in ['{}', 'x' * (FrameTemplateFiles.maxBytes + 1)]) {
        final files = FrameTemplateFiles(read: () async => source);
        await expectLater(
          files.importTemplate(canCommit: () => true),
          throwsA(isA<Exception>()),
        );
      }
      var writes = 0;
      final files = FrameTemplateFiles(
        write: (_, _, _) async {
          writes++;
          return 'export';
        },
      );
      await expectLater(
        files.exportTemplate(FrameTemplates.builtin, canCommit: () => false),
        throwsFormatException,
      );
      expect(writes, 0);
    },
  );
}
