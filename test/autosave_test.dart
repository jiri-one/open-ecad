// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ecad_core/ecad_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/app/controller.dart';
import 'package:open_ecad/app/workspace_controller.dart';
import 'package:open_ecad/services/document_session.dart';
import 'package:open_ecad/services/project_files_native.dart';
import 'package:open_ecad/services/project_persistence.dart';
import 'package:open_ecad/services/project_storage_native.dart';
import 'package:shared_preferences/shared_preferences.dart';

EcadProject _project(String name) => EcadProject(
  id: 'project',
  name: name,
  pages: [Sheet(id: 'sheet', name: 'Sheet', number: '01')],
);

class _SlowPersistence extends ProjectPersistence {
  final firstWrite = Completer<void>();
  final release = Completer<void>();
  final revisions = <int>[];

  @override
  Future<String> saveWorkingCopy(
    WorkingCopy copy, {
    EncodedProject? encoded,
  }) async {
    revisions.add(copy.project.revision);
    if (revisions.length == 1) {
      firstWrite.complete();
      await release.future;
    }
    return super.saveWorkingCopy(copy, encoded: encoded);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final parent = await Directory(
      '.ai/tests/autosave',
    ).create(recursive: true);
    directory = await parent.createTemp('case-');
  });
  tearDown(() => directory.delete(recursive: true));

  Future<File> writeProject(String name) => File(
    '${directory.path}/$name.oecad',
  ).writeAsString(jsonEncode(_project(name).toJson()));

  test(
    'edits, undo and redo update the opened file without a picker',
    () async {
      final file = await writeProject('original');
      var pickers = 0;
      final persistence = ProjectPersistence(
        files: PlatformProjectFiles(
          selectSave: (_, _) async {
            pickers++;
            return null;
          },
        ),
      );
      final app = EditorController(persistence: persistence, startEmpty: true);
      addTearDown(app.dispose);
      expect(await app.openProject(path: file.path), isTrue);
      app.renameProject('edited');
      expect(await app.flushWorkingCopy(), isTrue);
      expect(persistence.decode(await file.readAsString()).name, 'edited');
      app.undo();
      expect(await app.flushWorkingCopy(), isTrue);
      expect(persistence.decode(await file.readAsString()).name, 'original');
      app.redo();
      expect(await app.flushWorkingCopy(), isTrue);
      expect(persistence.decode(await file.readAsString()).name, 'edited');
      expect(pickers, 0);
      expect(app.changesSaved, isTrue);
      final checkpoint =
          (await persistence.loadAutosave(sessionId: app.documentSessionId))!;
      expect(
        checkpoint.currentFile!.version,
        (await persistence.files.readPath(file.path)).origin!.version,
      );
      expect(checkpoint.savedRevision, app.project.revision);
    },
  );

  test('edits during a slow checkpoint drain to the newest revision', () async {
    final persistence = _SlowPersistence();
    final app = EditorController(
      initialProject: _project('initial'),
      persistence: persistence,
    );
    addTearDown(app.dispose);
    app.renameProject('first');
    await persistence.firstWrite.future;
    app.renameProject('second');
    app.renameProject('third');
    final flushing = app.flushWorkingCopy();
    persistence.release.complete();
    expect(await flushing, isTrue);
    expect(persistence.revisions, [1, 3]);
    expect((await persistence.loadAutosave())!.project.name, 'third');
    expect(app.changesSaved, isTrue);
  });

  test(
    'restore uses a newer external file when the checkpoint was synchronized',
    () async {
      final file = await writeProject('original');
      final persistence = ProjectPersistence();
      final first = EditorController(persistence: persistence);
      await first.openProject(path: file.path);
      await first.flushWorkingCopy();
      final id = first.documentSessionId;
      first.dispose();
      await file.writeAsString(jsonEncode(_project('external').toJson()));
      final second = EditorController(persistence: persistence);
      addTearDown(second.dispose);
      expect(await second.restoreWorkingCopy(id), isTrue);
      expect(second.project.name, 'external');
      expect(await second.flushWorkingCopy(), isTrue);
      expect(persistence.decode(await file.readAsString()).name, 'external');
    },
  );

  test('restore reconciles a file commit made before its checkpoint', () async {
    final file = await writeProject('original');
    final persistence = ProjectPersistence();
    final session = DocumentSession(
      _project('initial'),
      persistence: persistence,
    );
    addTearDown(session.dispose);
    await session.open(path: file.path);
    session.engine.execute([const RenameProject('committed')]);
    final beforeCommit = session.workingCopy;
    await persistence.saveWorkingCopy(beforeCommit);
    expect(await session.save(), DocumentIoResult.saved);
    final restored = DocumentSession(
      _project('placeholder'),
      persistence: persistence,
    );
    addTearDown(restored.dispose);
    expect(
      await restored.restore(recoveryId: beforeCommit.sessionId),
      DocumentIoResult.restored,
    );
    expect(restored.dirty, isFalse);
    expect(restored.currentFile!.version, session.currentFile!.version);
    expect(await restored.autosave(), DocumentIoResult.saved);
  });

  test(
    'file conflicts keep a checkpoint and can continue as a local project',
    () async {
      final file = await writeProject('original');
      final persistence = ProjectPersistence();
      final app = EditorController(persistence: persistence);
      final workspace = WorkspaceController(app);
      addTearDown(workspace.dispose);
      addTearDown(app.dispose);
      await app.openProject(path: file.path);
      await app.flushWorkingCopy();
      final external = jsonEncode(_project('external').toJson());
      await file.writeAsString(external);
      app.renameProject('local edit');
      expect(await workspace.closeDocument(app), isFalse);
      expect(app.autosaveError, contains('Soubor se změnil'));
      expect(await file.readAsString(), external);
      expect(
        (await persistence.loadAutosave(
          sessionId: app.documentSessionId,
        ))!.project.name,
        'local edit',
      );
      expect(await app.continueLocally(), isTrue);
      expect(app.currentFile, isNull);
      expect(app.changesSaved, isTrue);
      expect(await workspace.closeDocument(app), isTrue);
      expect(await file.readAsString(), external);
    },
  );

  test(
    'a missing source file is reported after restore while its project remains available',
    () async {
      final file = await writeProject('original');
      final persistence = ProjectPersistence();
      final first = EditorController(persistence: persistence);
      await first.openProject(path: file.path);
      await first.flushWorkingCopy();
      final id = first.documentSessionId;
      first.dispose();
      await file.delete();
      final second = EditorController(persistence: persistence);
      addTearDown(second.dispose);
      expect(await second.restoreWorkingCopy(id), isTrue);
      expect(await second.flushWorkingCopy(), isFalse);
      expect(second.project.name, 'original');
      expect(second.autosaveError, isNotNull);
      expect(await second.continueLocally(), isTrue);
    },
  );

  test(
    'project copies cannot overwrite any open project and do not retarget autosave',
    () async {
      final a = await writeProject('a'), b = await writeProject('b');
      final copy = File('${directory.path}/copy.oecad');
      var destination = a.path;
      final persistence = ProjectPersistence(
        files: PlatformProjectFiles(selectSave: (_, _) async => destination),
      );
      final first = EditorController(persistence: persistence);
      final second = EditorController(persistence: persistence);
      final workspace = WorkspaceController(first);
      addTearDown(workspace.dispose);
      addTearDown(first.dispose);
      await first.openProject(path: a.path);
      await second.openProject(path: b.path);
      workspace.add(second);
      workspace.openSheet(first, first.activeSheetId);
      expect(await workspace.exportProjectCopy(), isFalse);
      destination = b.path;
      expect(await workspace.exportProjectCopy(), isFalse);
      expect(persistence.decode(await b.readAsString()).name, 'b');
      destination = copy.path;
      expect(await workspace.exportProjectCopy(), isTrue);
      expect(first.currentFile!.path, await a.resolveSymbolicLinks());
      first.renameProject('later');
      await first.flushWorkingCopy();
      expect(persistence.decode(await a.readAsString()).name, 'later');
      expect(persistence.decode(await copy.readAsString()).name, 'a');
    },
  );

  test(
    'native checkpoints replace atomically and preserve large projects across fresh storage instances',
    () async {
      final store = FileProjectStorage(directory: () async => directory);
      final persistence = ProjectPersistence(storage: store);
      final large = _project('large').copyWith(
        pages: [
          _project('large').pages.single.copyWith(
            graphics: [
              for (var i = 0; i < 2500; i++)
                DrawingElement(
                  id: 'text_$i',
                  kind: DrawingKind.text,
                  position: Vec2.zero,
                  width: 100,
                  height: 12,
                  text: 'x' * 1024,
                ),
            ],
          ),
        ],
      );
      final token = await persistence.saveWorkingCopy(
        WorkingCopy(_project('first'), sessionId: 'local'),
      );
      await persistence.saveWorkingCopy(
        WorkingCopy(large, sessionId: 'local', storageToken: token),
      );
      final reloaded = ProjectPersistence(
        storage: FileProjectStorage(directory: () async => directory),
      );
      expect(
        (await reloaded.loadAutosave(sessionId: 'local'))!.project.toJson(),
        large.toJson(),
      );
      expect(await reloaded.listRecoveryIds(), ['local']);
      expect(
        await directory.list().where((entry) => entry is Directory).toList(),
        isEmpty,
      );
      await expectLater(
        store.write('../escape', 'invalid', expectedToken: null),
        throwsFormatException,
      );
      expect(
        (await reloaded.loadAutosave(sessionId: 'local'))!.project.name,
        'large',
      );
    },
  );
}
