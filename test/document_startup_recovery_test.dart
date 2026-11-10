import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ecad_core/ecad_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/services/document_session.dart';
import 'package:open_ecad/services/project_persistence.dart';
import 'package:open_ecad/services/startup_options.dart';
import 'package:shared_preferences/shared_preferences.dart';

EcadProject _project(String name, {int revision = 0}) => EcadProject(
  id: 'synthetic_project',
  name: name,
  revision: revision,
  pages: [Sheet(id: 'synthetic_sheet', name: 'Sheet', number: '01')],
);

class _ObservedPersistence extends ProjectPersistence {
  int recoveryReads = 0;
  Completer<WorkingCopy?>? recovery;

  @override
  Future<WorkingCopy?> loadAutosave({String? sessionId}) {
    recoveryReads++;
    return recovery?.future ?? super.loadAutosave(sessionId: sessionId);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('startup arguments', () {
    test(
      'supports separated and equal syntax including spaces and Windows paths',
      () {
        for (final path in [
          '/tmp/a b.oecad',
          r'C:\Projects\a b.oecad',
          'relative.oecad',
        ]) {
          expect(StartupOptions.parse(['--project', path]).projectPath, path);
          expect(StartupOptions.parse(['--project=$path']).projectPath, path);
        }
        expect(StartupOptions.parse([]).explicitRequest, isFalse);
      },
    );

    test(
      'bad arguments remain explicit requests and cannot fall back to recovery',
      () {
        for (final args in [
          ['--project'],
          ['--project='],
          ['--project', ' '],
          ['--project', '--unknown'],
          ['--other', 'path'],
          ['--project', 'a', '--project', 'b'],
          ['--project=a', '--project=b'],
          ['file.oecad'],
        ]) {
          final options = StartupOptions.parse(args);
          expect(options.error, isNotNull, reason: args.toString());
          expect(options.explicitRequest, isTrue);
        }
        expect(
          StartupOptions.parse(['--project', 'path'], isWeb: true).error,
          isNotNull,
        );
      },
    );
  });

  group('startup and recovery', () {
    late Directory directory;
    late _ObservedPersistence persistence;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      directory = await Directory.systemTemp.createTemp(
        'open-ecad-startup-test-',
      );
      persistence = _ObservedPersistence();
    });
    tearDown(() async {
      await directory.delete(recursive: true);
    });

    DocumentSession createSession() {
      final session = DocumentSession(
        _project('initial'),
        persistence: persistence,
      );
      addTearDown(session.dispose);
      return session;
    }

    Future<File> writeProject(String name) => File(
      '${directory.path}/$name.oecad',
    ).writeAsString(jsonEncode(_project(name).toJson()));

    test(
      'explicit startup beats recovery without reading or overwriting it',
      () async {
        const legacy = 'synthetic unsupported recovery payload';
        SharedPreferences.setMockInitialValues({
          ProjectPersistence.autosaveKey: legacy,
        });
        final old = WorkingCopy(
          _project('previous work', revision: 3),
          sessionId: 'old',
          savedRevision: 1,
        );
        await persistence.saveWorkingCopy(old);
        final prefs = await SharedPreferences.getInstance();
        final previous = prefs.getString(
          '${ProjectPersistence.recoveryPrefix}old',
        );
        final file = await writeProject('startup');
        final session = createSession();
        expect(
          await session.initialize(startupProjectPath: file.path),
          DocumentIoResult.opened,
        );
        expect(persistence.recoveryReads, 0);
        expect(session.project.name, 'startup');
        expect(session.currentFile!.path, await file.resolveSymbolicLinks());
        await persistence.saveWorkingCopy(session.workingCopy);
        expect(
          prefs.getString('${ProjectPersistence.recoveryPrefix}old'),
          previous,
        );
        expect(prefs.getString(ProjectPersistence.autosaveKey), legacy);
        expect(
          await persistence.listRecoveryIds(),
          containsAll(['old', session.sessionId]),
        );
      },
    );

    test(
      'invalid or absent startup project leaves current document and recovery intact',
      () async {
        await persistence.saveWorkingCopy(
          WorkingCopy(_project('recoverable'), sessionId: 'old'),
        );
        final invalid = await File(
          '${directory.path}/invalid.oecad',
        ).writeAsString('{broken');
        for (final path in [invalid.path, '${directory.path}/missing.oecad']) {
          final session = createSession();
          session.engine.execute([const RenameProject('unsaved')]);
          final original = session.project;
          await expectLater(
            session.initialize(startupProjectPath: path),
            throwsA(anything),
          );
          expect(session.project, same(original));
          expect(session.currentFile, isNull);
          expect(session.dirty, isTrue);
        }
        expect(persistence.recoveryReads, 0);
        expect(await persistence.listRecoveryIds(), ['old']);
      },
    );

    test(
      'invalid startup options and explicit initial project skip recovery',
      () async {
        final invalid = createSession();
        await expectLater(
          invalid.initialize(startupError: 'Invalid --project'),
          throwsFormatException,
        );
        final supplied = createSession();
        expect(
          await supplied.initialize(restoreAutosave: false),
          DocumentIoResult.unchanged,
        );
        expect(persistence.recoveryReads, 0);
        expect(supplied.project.name, 'initial');
      },
    );

    test(
      'normal startup restores target and saved revision of its working copy',
      () async {
        final file = await writeProject('file');
        final first = createSession();
        await first.open(path: file.path);
        first.engine.execute([const RenameProject('recovered edits')]);
        await persistence.saveWorkingCopy(first.workingCopy);
        final restored = createSession();
        expect(await restored.initialize(), DocumentIoResult.restored);
        expect(restored.sessionId, first.sessionId);
        expect(restored.currentFile!.path, first.currentFile!.path);
        expect(restored.currentFile!.version, first.currentFile!.version);
        expect(restored.savedRevision, 0);
        expect(restored.dirty, isTrue);
        expect(await restored.save(), DocumentIoResult.saved);
        expect(
          persistence.decode(await file.readAsString()).name,
          'recovered edits',
        );
      },
    );

    test(
      'restored disk token rejects an external change after the working copy',
      () async {
        final file = await writeProject('file');
        final first = createSession();
        await first.open(path: file.path);
        first.engine.execute([const RenameProject('local edits')]);
        await persistence.saveWorkingCopy(first.workingCopy);
        await file.writeAsString(
          jsonEncode(_project('external edits').toJson()),
        );
        final restored = createSession();
        await restored.initialize();
        await expectLater(restored.save(), throwsA(isA<ProjectFileConflict>()));
        expect(
          persistence.decode(await file.readAsString()).name,
          'external edits',
        );
        expect(restored.dirty, isTrue);
      },
    );

    test(
      'late recovery cannot replace edits or an explicitly opened document',
      () async {
        persistence.recovery = Completer<WorkingCopy?>();
        final session = createSession();
        final restoring = session.initialize();
        final file = await writeProject('explicit');
        await session.open(path: file.path);
        persistence.recovery!.complete(
          WorkingCopy(_project('late'), sessionId: 'late'),
        );
        expect(await restoring, DocumentIoResult.superseded);
        expect(session.project.name, 'explicit');
        persistence.recovery = Completer<WorkingCopy?>();
        final edited = createSession();
        final pending = edited.initialize();
        edited.engine.execute([const RenameProject('edited')]);
        persistence.recovery!.complete(
          WorkingCopy(_project('late'), sessionId: 'late'),
        );
        expect(await pending, DocumentIoResult.superseded);
        expect(edited.project.name, 'edited');
      },
    );

    test(
      'ordered autosaves retain newest revision and other sessions',
      () async {
        final first = persistence.saveWorkingCopy(
          WorkingCopy(_project('first'), sessionId: 'a'),
        );
        await Future.wait([
          persistence.saveWorkingCopy(
            WorkingCopy(_project('other'), sessionId: 'b'),
          ),
          first.then(
            (token) => persistence.saveWorkingCopy(
              WorkingCopy(
                _project('latest', revision: 2),
                sessionId: 'a',
                storageToken: token,
              ),
            ),
          ),
        ]);
        expect((await persistence.loadAutosave())!.project.name, 'latest');
        expect(
          (await persistence.loadAutosave(sessionId: 'b'))!.project.name,
          'other',
        );
        expect(await persistence.listRecoveryIds(), ['a', 'b']);
        await persistence.removeWorkingCopy(
          'a',
          expectedToken:
              (await persistence.loadAutosave(sessionId: 'a'))!.storageToken,
        );
        expect((await persistence.loadAutosave())!.project.name, 'other');
      },
    );

    test(
      'oversize or unsupported recovery is preserved without claiming a save',
      () async {
        const legacy = 'synthetic older recovery';
        SharedPreferences.setMockInitialValues({
          ProjectPersistence.autosaveKey: legacy,
        });
        await expectLater(persistence.loadAutosave(), throwsFormatException);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString(ProjectPersistence.autosaveKey), legacy);
        await persistence.saveWorkingCopy(
          WorkingCopy(_project('previous'), sessionId: 'a'),
        );
        final previous = prefs.getString(
          '${ProjectPersistence.recoveryPrefix}a',
        );
        final oversized = _project('large').copyWith(
          description: 'x' * (ProjectPersistence.maxAutosaveBytes + 1),
        );
        await expectLater(
          persistence.saveWorkingCopy(WorkingCopy(oversized, sessionId: 'a')),
          throwsA(isA<AutosaveTooLargeException>()),
        );
        expect(
          prefs.getString('${ProjectPersistence.recoveryPrefix}a'),
          previous,
        );
        expect(prefs.getString(ProjectPersistence.autosaveKey), legacy);
        await prefs.setString(
          '${ProjectPersistence.recoveryPrefix}a',
          '{invalid',
        );
        await expectLater(persistence.loadAutosave(), throwsFormatException);
        expect(
          prefs.getString('${ProjectPersistence.recoveryPrefix}a'),
          '{invalid',
        );
      },
    );
  });
}
