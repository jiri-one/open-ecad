// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ecad_core/ecad_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/services/document_session.dart';
import 'package:open_ecad/services/export_fonts.dart';
import 'package:open_ecad/services/project_export.dart';
import 'package:open_ecad/services/project_files_native.dart';
import 'package:open_ecad/services/project_persistence.dart';
import 'package:open_ecad/services/report_layout.dart';

EcadProject _project(String name) => EcadProject(
  id: 'synthetic_project',
  name: name,
  pages: [Sheet(id: 'sheet', name: 'Sheet', number: '01')],
);

class _ObservedFiles implements ProjectFiles {
  _ObservedFiles(this.directory, {String? Function()? selectSave})
    : native = PlatformProjectFiles(
        selectSave: (_, _) async => selectSave?.call(),
      );

  final Directory directory;
  final PlatformProjectFiles native;
  void Function()? beforeCommit;
  void Function()? afterCommit;

  @override
  Future<ProjectFileData?> pick() => native.pick();
  @override
  Future<ProjectFileData> readPath(String path) => native.readPath(path);
  @override
  Future<SavedProjectFile?> save(
    Uint8List bytes, {
    required String suggestedName,
    required bool Function() canCommit,
    DocumentFileHandle? target,
    DocumentFileHandle? currentFile,
    Iterable<String> Function()? protectedPaths,
  }) => native.save(
    bytes,
    suggestedName: suggestedName,
    target: target,
    currentFile: currentFile,
    protectedPaths: protectedPaths,
    canCommit: () {
      if (directory.listSync().whereType<Directory>().isNotEmpty) {
        final before = beforeCommit;
        beforeCommit = null;
        before?.call();
        if (canCommit()) {
          final after = afterCommit;
          afterCommit = null;
          // The backend renames synchronously, then awaits staging cleanup.
          if (after != null) scheduleMicrotask(after);
        }
      }
      return canCommit();
    },
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('native document integrity', () {
    late Directory directory;
    late File file;
    late _ObservedFiles files;
    late DocumentSession session;
    String? selected;

    String diskName() =>
        (jsonDecode(file.readAsStringSync()) as Map)['name'] as String;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp(
        'open-ecad-io-regression-',
      );
      file = await File(
        '${directory.path}/target.oecad',
      ).writeAsString(jsonEncode(_project('original').toJson()));
      selected = null;
      files = _ObservedFiles(directory, selectSave: () => selected);
      session = DocumentSession(
        _project('initial'),
        persistence: ProjectPersistence(files: files),
      );
      await session.open(path: file.path);
    });
    tearDown(() async {
      session.dispose();
      await directory.delete(recursive: true);
    });

    for (final saveAs in [false, true]) {
      test(
        'Save after OS commit uses the committed token (Save As: $saveAs)',
        () async {
          session.engine.execute([const RenameProject('first')]);
          var returned = false;
          var observed = false;
          late Future<DocumentIoResult> second;
          files.afterCommit = () {
            observed = true;
            expect(returned, isFalse);
            expect(diskName(), 'first');
            session.engine.execute([const RenameProject('second')]);
            selected = file.path;
            second = session.save(saveAs: saveAs);
          };
          final first = await session.save();
          returned = true;
          expect(observed, isTrue);
          expect(first, DocumentIoResult.superseded);
          expect(await second, DocumentIoResult.saved);
          expect(diskName(), 'second');
          expect(
            session.currentFile!.version,
            (await files.readPath(file.path)).origin!.version,
          );
          expect(session.savedRevision, 2);
          expect(session.dirty, isFalse);
          session.engine.execute([const RenameProject('third')]);
          expect(await session.save(), DocumentIoResult.saved);
          expect(diskName(), 'third');
          expect(directory.listSync().whereType<Directory>(), isEmpty);
        },
      );
    }

    test(
      'external edit after our commit still conflicts with the queued Save',
      () async {
        session.engine.execute([const RenameProject('first')]);
        late Future<void> second;
        String? committedVersion;
        files.afterCommit = () {
          expect(diskName(), 'first');
          session.engine.execute([const RenameProject('second')]);
          file.writeAsStringSync(jsonEncode(_project('external').toJson()));
          second = expectLater(
            session.save(),
            throwsA(isA<ProjectFileConflict>()),
          );
        };
        expect(await session.save(), DocumentIoResult.superseded);
        committedVersion = session.currentFile!.version;
        await second;
        expect(diskName(), 'external');
        expect(session.project.name, 'second');
        expect(session.savedRevision, 1);
        expect(session.dirty, isTrue);
        expect(session.currentFile!.version, committedVersion);
        expect(
          committedVersion,
          isNot((await files.readPath(file.path)).origin!.version),
        );
        await expectLater(session.save(), throwsA(isA<ProjectFileConflict>()));
        expect(directory.listSync().whereType<Directory>(), isEmpty);
      },
    );

    test(
      'newer Save invalidates the staged older snapshot before commit',
      () async {
        session.engine.execute([const RenameProject('first')]);
        late Future<DocumentIoResult> second;
        files.beforeCommit = () {
          expect(diskName(), 'original');
          session.engine.execute([const RenameProject('second')]);
          second = session.save();
        };
        expect(await session.save(), DocumentIoResult.superseded);
        expect(diskName(), 'original');
        expect(await second, DocumentIoResult.saved);
        expect(diskName(), 'second');
        expect(session.dirty, isFalse);
        expect(directory.listSync().whereType<Directory>(), isEmpty);
      },
    );

    test(
      'canceled newer Save As keeps the already committed handle and revision',
      () async {
        session.engine.execute([const RenameProject('first')]);
        late Future<DocumentIoResult> second;
        files.afterCommit = () {
          expect(diskName(), 'first');
          session.engine.execute([const RenameProject('second')]);
          second = session.save(saveAs: true);
        };
        expect(await session.save(), DocumentIoResult.superseded);
        expect(await second, DocumentIoResult.canceled);
        expect(session.savedRevision, 1);
        expect(
          session.currentFile!.version,
          (await files.readPath(file.path)).origin!.version,
        );
        expect(session.dirty, isTrue);
        expect(await session.save(), DocumentIoResult.saved);
        expect(diskName(), 'second');
      },
    );

    for (final replaceAfterCommit in [false, true]) {
      test(
        'document replacement invalidates pending writes (after commit: $replaceAfterCommit)',
        () async {
          session.engine.execute([const RenameProject('first')]);
          late Future<DocumentIoResult> queued;
          void replace() {
            queued = session.save();
            session.replace(_project('replacement'));
          }

          if (replaceAfterCommit) {
            files.afterCommit = replace;
          } else {
            files.beforeCommit = replace;
          }
          expect(await session.save(), DocumentIoResult.superseded);
          expect(await queued, DocumentIoResult.superseded);
          expect(diskName(), replaceAfterCommit ? 'first' : 'original');
          expect(session.project.name, 'replacement');
          expect(session.currentFile, isNull);
          expect(session.savedRevision, isNull);
          expect(directory.listSync().whereType<Directory>(), isEmpty);
        },
      );
    }

    for (final mode in [0x180, 0x1a0]) {
      test(
        'atomic replacement preserves POSIX mode ${mode.toRadixString(8)}',
        () async {
          expect(
            (await Process.run('/bin/chmod', [
              mode.toRadixString(8),
              file.path,
            ])).exitCode,
            0,
          );
          expect((await file.stat()).mode & 0xfff, mode);
          session.engine.execute([const RenameProject('restricted')]);
          expect(await session.save(), DocumentIoResult.saved);
          expect(diskName(), 'restricted');
          expect((await file.stat()).mode & 0xfff, mode);
          expect(
            session.currentFile!.version,
            (await files.readPath(file.path)).origin!.version,
          );
          expect(directory.listSync().whereType<Directory>(), isEmpty);
        },
        skip: Platform.isWindows ? 'POSIX permissions' : false,
      );
    }
  });

  test(
    'unassigned BOM identities survive CSV and SVG export and report layout',
    () async {
      await ExportFonts.load();
      final sheet = Sheet(
        id: 'bom',
        name: 'BOM',
        number: 'B1',
        type: SheetType.billOfMaterials,
        report: const BomTableSpec(kind: BomReportKind.articles),
      );
      final project = EcadProject(
        id: 'bom_project',
        name: 'Synthetic BOM',
        pages: [sheet],
        components: [
          const Component(id: 'ca', designation: '-K1'),
          const Component(id: 'cb', designation: '-K2'),
        ],
      );
      final exporter = ProjectExportService();
      final csv = exporter.csv(project, sheetId: sheet.id);
      final svg = exporter.svg(project, sheetId: sheet.id);
      final layout = layoutReport(project, sheet);
      final printed =
          layout.pages.expand((p) => p.texts).map((t) => t.text).toList();
      for (final designation in ['-K1', '-K2']) {
        expect(csv, contains('"\'$designation"'));
        expect(svg, contains('>$designation</text>'));
        expect(printed, contains(designation));
      }
      expect(csv.trim().split('\r\n'), hasLength(3));
      expect(layout.data.rows, hasLength(2));
      for (final row in layout.data.rows) {
        expect(row.cells.skip(3), ['ks', '1', '0', '0', '0', '1']);
      }
      expect(project.articles, isEmpty);
    },
  );
}
