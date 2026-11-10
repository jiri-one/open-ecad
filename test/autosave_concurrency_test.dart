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
  id: 'synthetic-project',
  name: name,
  pages: [Sheet(id: 'sheet', name: 'Sheet', number: '1')],
);

class _UnavailableCheckpoint extends ProjectPersistence {
  _UnavailableCheckpoint({required super.storage});
  @override
  Future<String> saveWorkingCopy(
    WorkingCopy copy, {
    EncodedProject? encoded,
  }) async => throw StateError('Local storage unavailable');
}

class _InterruptedCheckpoint extends ProjectPersistence {
  _InterruptedCheckpoint({required super.storage});
  final started = Completer<void>(), release = Completer<void>();
  int writes = 0;
  @override
  Future<String> saveWorkingCopy(
    WorkingCopy copy, {
    EncodedProject? encoded,
  }) async {
    if (++writes == 1) {
      started.complete();
      await release.future;
    } else {
      throw StateError('Interrupted metadata checkpoint');
    }
    return super.saveWorkingCopy(copy, encoded: encoded);
  }
}

class _DelayedOpen extends ProjectPersistence {
  _DelayedOpen({required super.storage, required super.files});
  final started = Completer<void>(), release = Completer<void>();
  @override
  Future<LoadedProject> loadPath(String path) async {
    final loaded = await super.loadPath(path);
    started.complete();
    await release.future;
    return loaded;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final parent = await Directory(
      '.ai/tests/autosave-concurrency',
    ).create(recursive: true);
    directory = await parent.createTemp('case-');
  });
  tearDown(() async {
    await ProjectPersistence().listRecoveryIds();
    await directory.delete(recursive: true);
  });

  FileProjectStorage store() => FileProjectStorage(
    directory: () async => Directory('${directory.path}/store'),
  );
  Future<File> source(String name) => File(
    '${directory.path}/source.oecad',
  ).writeAsString(jsonEncode(_project(name).toJson()));

  test(
    'an unchanged second window closes without overwriting acknowledged edits',
    () async {
      final first = EditorController(
        initialProject: _project('Initial'),
        persistence: ProjectPersistence(storage: store()),
      );
      addTearDown(first.dispose);
      await first.flushWorkingCopy();
      final id = first.documentSessionId;
      final second = EditorController(
        startEmpty: true,
        autosaveEnabled: false,
        persistence: ProjectPersistence(storage: store()),
      );
      addTearDown(second.dispose);
      expect(await second.restoreWorkingCopy(id), isTrue);
      first.renameProject('Saved in first window');
      expect(await first.flushWorkingCopy(), isTrue);
      final workspace = WorkspaceController(second);
      addTearDown(workspace.dispose);
      expect(await workspace.closeDocument(second), isTrue);
      final restored =
          (await ProjectPersistence(
            storage: store(),
          ).loadAutosave(sessionId: id))!;
      expect(restored.project.name, 'Saved in first window');
      expect(restored.project.revision, 1);
    },
  );

  test(
    'a stale edited window forks explicitly and preserves both local projects',
    () async {
      final first = EditorController(
        initialProject: _project('Initial'),
        persistence: ProjectPersistence(storage: store()),
      );
      addTearDown(first.dispose);
      await first.flushWorkingCopy();
      final originalId = first.documentSessionId;
      final second = EditorController(
        startEmpty: true,
        persistence: ProjectPersistence(storage: store()),
      );
      addTearDown(second.dispose);
      await second.restoreWorkingCopy(originalId);
      await second.flushWorkingCopy();
      first.renameProject('First owner');
      await first.flushWorkingCopy();
      second.renameProject('Second owner');
      expect(await second.flushWorkingCopy(), isFalse);
      expect(second.canContinueLocally, isTrue);
      expect(await second.continueLocally(), isTrue);
      expect(second.documentSessionId, isNot(originalId));
      expect(second.canUndo, isTrue);
      final persistence = ProjectPersistence(storage: store());
      expect(
        (await persistence.loadAutosave(sessionId: originalId))!.project.name,
        'First owner',
      );
      expect(
        (await persistence.loadAutosave(
          sessionId: second.documentSessionId,
        ))!.project.name,
        'Second owner',
      );
    },
  );

  test(
    'a failed local checkpoint still saves a healthy source and allows close',
    () async {
      final file = await source('Original');
      final persistence = _UnavailableCheckpoint(storage: store());
      final app = EditorController(startEmpty: true, persistence: persistence);
      final workspace = WorkspaceController(app);
      addTearDown(workspace.dispose);
      addTearDown(app.dispose);
      expect(await app.openProject(path: file.path), isTrue);
      app.renameProject('Saved to source');
      expect(await app.flushWorkingCopy(), isTrue);
      expect(
        persistence.decode(await file.readAsString()).name,
        'Saved to source',
      );
      expect(app.currentFile!.path, await file.resolveSymbolicLinks());
      expect(app.autosaveError, isNull);
      expect(app.autosaveWarning, contains('Local storage unavailable'));
      expect(await app.continueLocally(), isFalse);
      expect(app.currentFile, isNotNull);
      expect(await workspace.closeDocument(app), isTrue);
    },
  );

  test(
    'an edit during checkpointing cannot get ahead of interrupted commit recovery',
    () async {
      final file = await source('Original');
      final persistence = _InterruptedCheckpoint(storage: store());
      final first = DocumentSession(
        _project('Placeholder'),
        persistence: persistence,
      );
      addTearDown(first.dispose);
      await first.open(path: file.path);
      final id = first.sessionId;
      first.engine.execute([const RenameProject('Checkpointed')]);
      final saving = first.autosave();
      await persistence.started.future;
      first.engine.execute([const RenameProject('Still pending')]);
      persistence.release.complete();
      expect(await saving, DocumentIoResult.saved);
      expect(first.dirty, isTrue);
      expect(
        persistence.decode(await file.readAsString()).name,
        'Checkpointed',
      );
      final restored = DocumentSession(
        _project('Placeholder'),
        persistence: ProjectPersistence(storage: store()),
      );
      addTearDown(restored.dispose);
      expect(await restored.restore(recoveryId: id), DocumentIoResult.restored);
      expect(restored.project.name, 'Checkpointed');
      expect(restored.dirty, isFalse);
      expect(await restored.autosave(), DocumentIoResult.saved);
    },
  );

  test('export rejects a source adopted after its picker opened', () async {
    final file = await source('Other source');
    final entered = Completer<void>(), destination = Completer<String?>();
    final persistence = _DelayedOpen(
      storage: store(),
      files: PlatformProjectFiles(
        selectSave: (_, _) {
          entered.complete();
          return destination.future;
        },
      ),
    );
    final first = EditorController(
      initialProject: _project('Exporting'),
      persistence: persistence,
    );
    final workspace = WorkspaceController(first);
    addTearDown(workspace.dispose);
    addTearDown(first.dispose);
    final opening = workspace.open(path: file.path);
    await persistence.started.future;
    final exporting = workspace.exportProjectCopy(document: first);
    await entered.future;
    persistence.release.complete();
    expect(await opening, isTrue);
    await workspace.active.flushWorkingCopy();
    destination.complete(file.path);
    expect(await exporting, isFalse);
    expect(persistence.decode(await file.readAsString()).name, 'Other source');
  });

  test(
    'reopening a synchronized source reuses its cache and closing makes no blank records',
    () async {
      final file = await source('Repeated file');
      final persistence = ProjectPersistence(storage: store());
      final initial = EditorController(
        startEmpty: true,
        persistence: persistence,
      );
      final workspace = WorkspaceController(initial);
      addTearDown(workspace.dispose);
      addTearDown(initial.dispose);
      for (var i = 0; i < 3; i++) {
        expect(await workspace.open(path: file.path), isTrue);
        expect(await workspace.closeDocument(workspace.active), isTrue);
      }
      expect(await persistence.listRecoveryIds(), hasLength(1));
      expect(await workspace.closeDocument(initial), isTrue);
      expect(await workspace.active.flushWorkingCopy(), isTrue);
      expect(await persistence.listRecoveryIds(), hasLength(1));
    },
  );

  test(
    'failed explicit startup preserves previous checkpoints and the active marker',
    () async {
      final persistence = ProjectPersistence(storage: store());
      final previous = EditorController(
        initialProject: _project('Previous'),
        persistence: persistence,
      );
      await previous.flushWorkingCopy();
      final id = previous.documentSessionId;
      await persistence.rememberStartupProject(id);
      previous.dispose();
      final failed = EditorController(
        startEmpty: true,
        persistence: persistence,
      );
      final workspace = WorkspaceController(failed);
      addTearDown(workspace.dispose);
      addTearDown(failed.dispose);
      await failed.initialize(
        startupProjectPath: '${directory.path}/missing.oecad',
      );
      expect(failed.canRememberStartup, isFalse);
      expect(await failed.flushWorkingCopy(), isTrue);
      expect(await persistence.listRecoveryIds(), [id]);
      final restored = EditorController(
        startEmpty: true,
        persistence: persistence,
      );
      addTearDown(restored.dispose);
      await restored.initialize();
      expect(restored.project.name, 'Previous');
      expect(await restored.flushWorkingCopy(), isTrue);
    },
  );

  test(
    'pending recovery reports an open source instead of silently dropping changes',
    () async {
      final file = await source('On disk');
      final persistence = ProjectPersistence(storage: store());
      final original = DocumentSession(
        _project('Placeholder'),
        persistence: persistence,
      );
      await original.open(path: file.path);
      await original.autosave();
      original.engine.execute([const RenameProject('Pending recovery')]);
      final pendingId = original.sessionId;
      await persistence.saveWorkingCopy(original.workingCopy);
      original.dispose();
      final initial = EditorController(
        startEmpty: true,
        persistence: persistence,
      );
      final workspace = WorkspaceController(initial);
      addTearDown(workspace.dispose);
      addTearDown(initial.dispose);
      expect(await workspace.open(path: file.path), isTrue);
      await workspace.active.flushWorkingCopy();
      expect(await workspace.restore(pendingId), isFalse);
      expect(workspace.active.project.name, 'On disk');
      expect(workspace.active.status, contains('Místní změny nebyly obnoveny'));
      expect(
        (await persistence.loadAutosave(sessionId: pendingId))!.project.name,
        'Pending recovery',
      );
    },
  );
}
