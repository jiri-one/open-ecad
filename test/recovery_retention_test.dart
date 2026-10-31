// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:ecad_core/ecad_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/app/controller.dart';
import 'package:open_ecad/app/workspace_controller.dart';
import 'package:open_ecad/services/document_session.dart';
import 'package:open_ecad/services/project_persistence.dart';
import 'package:shared_preferences/shared_preferences.dart';

EcadProject _project(String name) => EcadProject(
  id: 'project-$name',
  name: name,
  pages: [Sheet(id: 'sheet', name: 'Sheet', number: '01')],
);

WorkingCopy _copy(EditorController app) => WorkingCopy(
  app.project,
  sessionId: app.documentSessionId,
  savedRevision: app.savedRevision,
  fileName: app.fileName,
  currentFile: app.currentFile,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'retention bounds both the recovery index and stored payloads',
    () async {
      final persistence = ProjectPersistence();
      final count = ProjectPersistence.maxRetainedRecoveryCopies + 3;
      for (var i = 0; i < count; i++) {
        await persistence.saveWorkingCopy(
          WorkingCopy(_project('Project $i'), sessionId: 'session-$i'),
        );
      }
      final expected = [for (var i = count - 1; i >= 3; i--) 'session-$i'];
      expect(await persistence.listRecoveryIds(), expected);
      final preferences = await SharedPreferences.getInstance();
      for (var i = 0; i < count; i++) {
        expect(
          preferences.containsKey(
            '${ProjectPersistence.recoveryPrefix}session-$i',
          ),
          i >= 3,
        );
      }
      await persistence.saveWorkingCopy(
        WorkingCopy(_project('Updated'), sessionId: 'session-3'),
      );
      expect((await persistence.listRecoveryIds()).first, 'session-3');
      expect(
        await persistence.listRecoveryIds(),
        hasLength(ProjectPersistence.maxRetainedRecoveryCopies),
      );
      expect((await persistence.loadAutosave())!.project.name, 'Updated');
    },
  );

  test(
    'open recovery owners are protected until the last owner releases the session',
    () async {
      final persistence = ProjectPersistence();
      final first = DocumentSession(_project('Open'), persistence: persistence);
      final second = DocumentSession(
        _project('Temporary'),
        persistence: persistence,
      );
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      await persistence.saveWorkingCopy(first.workingCopy);
      final id = first.sessionId;
      expect(await second.restore(recoveryId: id), DocumentIoResult.restored);
      first.dispose();
      for (
        var i = 0;
        i < ProjectPersistence.maxRetainedRecoveryCopies + 2;
        i++
      ) {
        await persistence.saveWorkingCopy(
          WorkingCopy(_project('Closed $i'), sessionId: 'closed-$i'),
        );
      }
      expect(
        (await persistence.loadAutosave(sessionId: id))!.project.name,
        'Open',
      );
      expect(
        await persistence.listRecoveryIds(),
        hasLength(ProjectPersistence.maxRetainedRecoveryCopies + 1),
      );
      second.dispose();
      await persistence.saveWorkingCopy(
        WorkingCopy(_project('Newest'), sessionId: 'newest'),
      );
      expect(
        await persistence.listRecoveryIds(),
        hasLength(ProjectPersistence.maxRetainedRecoveryCopies),
      );
      await expectLater(
        persistence.loadAutosave(sessionId: id),
        throwsFormatException,
      );
    },
  );

  test(
    'resolved explicit close removes queued snapshots of only that document',
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
      addTearDown(kept.dispose);
      closed.renameProject('Edited before close');
      kept.renameProject('Edited and kept');
      await persistence.saveWorkingCopy(_copy(kept));
      final id = closed.documentSessionId;
      final pending = persistence.saveWorkingCopy(_copy(closed));
      workspace.closeDocument(closed);
      await pending;
      expect(await persistence.listRecoveryIds(), [kept.documentSessionId]);
      await expectLater(
        persistence.loadAutosave(sessionId: id),
        throwsFormatException,
      );
      expect(
        (await persistence.loadAutosave(
          sessionId: kept.documentSessionId,
        ))!.project.name,
        'Edited and kept',
      );
      expect(kept.dirty, isTrue);
    },
  );

  test(
    'disposing a workspace preserves recovery for the next launch',
    () async {
      final persistence = ProjectPersistence();
      final app = EditorController(
        initialProject: _project('Recoverable'),
        persistence: persistence,
      );
      final workspace = WorkspaceController(app);
      addTearDown(app.dispose);
      app.renameProject('Pending work');
      final id = app.documentSessionId;
      await persistence.saveWorkingCopy(_copy(app));
      workspace.dispose();
      app.dispose();
      final recovery = await persistence.loadAutosave(sessionId: id);
      expect(recovery!.project.name, 'Pending work');
      expect(recovery.savedRevision, 0);
      expect(recovery.project.revision, 1);
    },
  );
}
