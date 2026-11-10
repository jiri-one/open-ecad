// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:ecad_core/ecad_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/app/controller.dart';
import 'package:open_ecad/app/workspace_controller.dart';
import 'package:open_ecad/services/project_persistence.dart';
import 'package:shared_preferences/shared_preferences.dart';

EcadProject _project(String name) => EcadProject(
  id: 'project',
  name: name,
  pages: [Sheet(id: 'sheet', name: 'Sheet', number: '01')],
);

class _FailingPersistence extends ProjectPersistence {
  bool fail = true;

  @override
  Future<String> saveWorkingCopy(
    WorkingCopy copy, {
    EncodedProject? encoded,
  }) async {
    if (fail) throw StateError('Disk full');
    return super.saveWorkingCopy(copy, encoded: encoded);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('local projects are never evicted by newer projects', () async {
    final persistence = ProjectPersistence();
    for (var i = 0; i < 24; i++) {
      await persistence.saveWorkingCopy(
        WorkingCopy(_project('Project $i'), sessionId: 'session-$i'),
      );
    }
    expect(await persistence.listRecoveryIds(), hasLength(24));
    expect(
      (await persistence.loadAutosave(sessionId: 'session-0'))!.project.name,
      'Project 0',
    );
    await persistence.saveWorkingCopy(
      WorkingCopy(
        _project('Updated'),
        sessionId: 'session-0',
        storageToken:
            (await persistence.loadAutosave(
              sessionId: 'session-0',
            ))!.storageToken,
      ),
    );
    expect((await persistence.listRecoveryIds()).first, 'session-0');
    expect(await persistence.listRecoveryIds(), hasLength(24));
  });

  test(
    'closing a project saves its final edit and keeps it available to reopen',
    () async {
      final persistence = ProjectPersistence();
      final closed = EditorController(
        initialProject: _project('Closed'),
        persistence: persistence,
      );
      final kept = EditorController(
        initialProject: _project('Kept'),
        persistence: persistence,
      );
      final workspace = WorkspaceController(closed)..add(kept);
      addTearDown(workspace.dispose);
      addTearDown(closed.dispose);
      closed.renameProject('Edited immediately before close');
      kept.renameProject('Kept');
      final id = closed.documentSessionId;
      expect(await workspace.closeDocument(closed), isTrue);
      expect(workspace.documents, [kept]);
      expect(
        (await persistence.loadAutosave(sessionId: id))!.project.name,
        'Edited immediately before close',
      );
      expect(await workspace.restore(id), isTrue);
      expect(workspace.active.project.name, 'Edited immediately before close');
      expect(workspace.active.canUndo, isFalse);
    },
  );

  test('a failed autosave prevents close and can be retried', () async {
    final persistence = _FailingPersistence();
    final app = EditorController(
      initialProject: _project('Recoverable'),
      persistence: persistence,
    );
    final workspace = WorkspaceController(app);
    addTearDown(workspace.dispose);
    addTearDown(app.dispose);
    app.renameProject('Keep me');
    expect(await workspace.closeDocument(app), isFalse);
    expect(workspace.documents, [app]);
    expect(app.autosaveError, contains('Disk full'));
    expect(app.changesSaved, isFalse);
    persistence.fail = false;
    expect(await workspace.closeDocument(app), isTrue);
    expect(
      (await persistence.loadAutosave(
        sessionId: app.documentSessionId,
      ))!.project.name,
      'Keep me',
    );
  });

  test('saving before disposal preserves the next launch', () async {
    final persistence = ProjectPersistence();
    final app = EditorController(
      initialProject: _project('Recoverable'),
      persistence: persistence,
    );
    final workspace = WorkspaceController(app);
    app.renameProject('Pending work');
    final id = app.documentSessionId;
    expect(await app.flushWorkingCopy(), isTrue);
    workspace.dispose();
    app.dispose();
    final recovery = (await persistence.loadAutosave(sessionId: id))!;
    expect(recovery.project.name, 'Pending work');
    expect(recovery.savedRevision, recovery.project.revision);
  });
}
