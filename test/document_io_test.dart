import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ecad_core/ecad_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/services/document_session.dart';
import 'package:open_ecad/services/project_files_native.dart';
import 'package:open_ecad/services/project_persistence.dart';

EcadProject _project(String name) => EcadProject(
  id: 'synthetic_project',
  name: name,
  pages: [Sheet(id: 'synthetic_sheet', name: 'Sheet', number: '01')],
);

class _ControlledPersistence extends ProjectPersistence {
  final loads = <Completer<LoadedProject?>>[];
  final saves =
      <
        ({
          EcadProject snapshot,
          DocumentFileHandle? target,
          bool Function() canCommit,
          Completer<SavedProjectFile?> result,
        })
      >[];

  @override
  Future<LoadedProject?> pickAndLoad() {
    final result = Completer<LoadedProject?>();
    loads.add(result);
    return result.future;
  }

  @override
  Future<SavedProjectFile?> saveAs(
    EcadProject project, {
    DocumentFileHandle? currentFile,
    required bool Function() canCommit,
  }) => _save(project, null, canCommit);

  @override
  Future<SavedProjectFile?> saveTo(
    EcadProject project,
    DocumentFileHandle target, {
    required bool Function() canCommit,
  }) => _save(project, target, canCommit);

  Future<SavedProjectFile?> _save(
    EcadProject snapshot,
    DocumentFileHandle? target,
    bool Function() canCommit,
  ) {
    final result = Completer<SavedProjectFile?>();
    saves.add((
      snapshot: snapshot,
      target: target,
      canCommit: canCommit,
      result: result,
    ));
    return result.future;
  }
}

const _savedFile = SavedProjectFile(
  origin: DocumentFileHandle(
    path: '/synthetic/saved.oecad',
    version: 'version-1',
  ),
  name: 'saved.oecad',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('native project files', () {
    late Directory directory;
    late ProjectPersistence persistence;
    late DocumentSession session;
    String? selected;
    var dialogs = 0;

    Future<File> write(String name, EcadProject project) => File(
      '${directory.path}/$name.oecad',
    ).writeAsString(jsonEncode(project.toJson()));

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('open-ecad-io-test-');
      selected = null;
      dialogs = 0;
      persistence = ProjectPersistence(
        files: PlatformProjectFiles(
          selectOpen: () async => selected,
          selectSave: (_, _) async {
            dialogs++;
            return selected;
          },
        ),
      );
      session = DocumentSession(_project('initial'), persistence: persistence);
    });
    tearDown(() async {
      session.dispose();
      await directory.delete(recursive: true);
    });

    test('open A then B, rename B, and save only B without a dialog', () async {
      final a = await write('a', _project('alpha'));
      final b = await write('b', _project('bravo'));
      final originalA = await a.readAsString();
      await session.open(path: a.path);
      final firstSession = session.sessionId;
      await session.open(path: b.path);
      expect(session.sessionId, isNot(firstSession));
      session.engine.execute([const RenameProject('renamed')]);
      expect(await session.save(), DocumentIoResult.saved);
      expect(dialogs, 0);
      expect(session.currentFile!.path, await b.resolveSymbolicLinks());
      expect(session.dirty, isFalse);
      expect(await a.readAsString(), originalA);
      expect(persistence.decode(await b.readAsString()).name, 'renamed');
      session.engine.execute([const RenameProject('saved again')]);
      expect(await session.save(), DocumentIoResult.saved);
      expect(persistence.decode(await b.readAsString()).name, 'saved again');
    });

    test('relative paths resolve to a stable absolute handle', () async {
      final file = await write('relative', _project('relative'));
      final cwd =
          Directory.current.absolute.uri.pathSegments
              .where((part) => part.isNotEmpty)
              .toList();
      final destination = file.absolute.uri.pathSegments;
      var shared = 0;
      while (shared < cwd.length &&
          shared < destination.length &&
          cwd[shared] == destination[shared]) {
        shared++;
      }
      final relative = [
        ...List.filled(cwd.length - shared, '..'),
        ...destination.skip(shared),
      ].join(Platform.pathSeparator);
      final loaded = await persistence.loadPath(relative);
      expect(loaded.origin!.path, await file.resolveSymbolicLinks());
    });

    test(
      'canceled and invalid open preserve document, path and history',
      () async {
        final file = await write('valid', _project('valid'));
        await session.open(path: file.path);
        session.engine.execute([const RenameProject('edited')]);
        final snapshot = session.workingCopy;
        expect(await session.open(), DocumentIoResult.canceled);
        final invalid = await File(
          '${directory.path}/invalid.oecad',
        ).writeAsString('{broken');
        await expectLater(
          session.open(path: invalid.path),
          throwsFormatException,
        );
        expect(session.project, same(snapshot.project));
        expect(session.currentFile, same(snapshot.currentFile));
        expect(session.savedRevision, snapshot.savedRevision);
        expect(session.sessionId, snapshot.sessionId);
        expect(session.engine.canUndo, isTrue);
      },
    );

    test('open selection retains its path for the next Save', () async {
      final file = await write('picked', _project('picked'));
      selected = file.path;
      expect(await session.open(), DocumentIoResult.opened);
      expect(session.currentFile!.path, await file.resolveSymbolicLinks());
      session.engine.execute([const RenameProject('picked and edited')]);
      await session.save();
      expect(dialogs, 0);
      expect(
        persistence.decode(await file.readAsString()).name,
        'picked and edited',
      );
    });

    test(
      'Save As switches target only after success; subsequent Save uses it',
      () async {
        final original = await write('original', _project('original'));
        final before = await original.readAsString();
        await session.open(path: original.path);
        session.engine.execute([const RenameProject('changed')]);
        final target = File('${directory.path}/copy.oecad');
        selected = target.path;
        expect(await session.save(saveAs: true), DocumentIoResult.saved);
        expect(session.currentFile!.path, await target.resolveSymbolicLinks());
        expect(dialogs, 1);
        session.engine.execute([const RenameProject('changed again')]);
        await session.save();
        expect(dialogs, 1);
        expect(await original.readAsString(), before);
        expect(
          persistence.decode(await target.readAsString()).name,
          'changed again',
        );
      },
    );

    test(
      'Save As cancel and failure leave target and dirty state intact',
      () async {
        final file = await write('original', _project('original'));
        await session.open(path: file.path);
        session.engine.execute([const RenameProject('edited')]);
        final copy = session.workingCopy;
        expect(await session.save(saveAs: true), DocumentIoResult.canceled);
        expect(session.currentFile, same(copy.currentFile));
        expect(session.savedRevision, copy.savedRevision);
        expect(session.dirty, isTrue);
        selected = '${directory.path}/missing-parent/target.oecad';
        await expectLater(
          session.save(saveAs: true),
          throwsA(isA<FileSystemException>()),
        );
        expect(session.currentFile, same(copy.currentFile));
        expect(session.savedRevision, copy.savedRevision);
        expect(session.dirty, isTrue);
        expect(persistence.decode(await file.readAsString()).name, 'original');
      },
    );

    test(
      'external equal-size edit with restored timestamp blocks Save and same-path Save As',
      () async {
        final file = await write('original', _project('alpha'));
        await session.open(path: file.path);
        final modified = await file.lastModified();
        await file.writeAsString(jsonEncode(_project('bravo').toJson()));
        await file.setLastModified(modified);
        final external = await file.readAsBytes();
        session.engine.execute([const RenameProject('local')]);
        await expectLater(session.save(), throwsA(isA<ProjectFileConflict>()));
        selected = file.path;
        await expectLater(
          session.save(saveAs: true),
          throwsA(isA<ProjectFileConflict>()),
        );
        expect(await file.readAsBytes(), external);
        expect(session.dirty, isTrue);
        expect(directory.listSync().whereType<Directory>(), isEmpty);
      },
    );

    test('deleted original is a conflict, not silently recreated', () async {
      final file = await write('original', _project('alpha'));
      await session.open(path: file.path);
      await file.delete();
      await expectLater(session.save(), throwsA(isA<ProjectFileConflict>()));
      expect(await file.exists(), isFalse);
    });

    test('late Save As selection cannot write a replaced document', () async {
      final choice = Completer<String?>();
      final dialogStarted = Completer<void>();
      persistence = ProjectPersistence(
        files: PlatformProjectFiles(
          selectSave: (_, _) {
            dialogStarted.complete();
            return choice.future;
          },
        ),
      );
      session = DocumentSession(_project('old'), persistence: persistence);
      final saving = session.save(saveAs: true);
      await dialogStarted.future;
      session.replace(_project('replacement'));
      final target = File('${directory.path}/late.oecad');
      choice.complete(target.path);
      expect(await saving, DocumentIoResult.superseded);
      expect(await target.exists(), isFalse);
      expect(session.currentFile, isNull);
      expect(session.dirty, isTrue);
    });

    test(
      'invalidated final commit preserves original and cleans staging file',
      () async {
        final file = await write('original', _project('alpha'));
        final files = PlatformProjectFiles();
        final loaded = await files.readPath(file.path);
        final before = await file.readAsBytes();
        await expectLater(
          files.save(
            Uint8List.fromList(
              utf8.encode(jsonEncode(_project('changed').toJson())),
            ),
            target: loaded.origin,
            suggestedName: 'unused.oecad',
            canCommit:
                () => directory.listSync().whereType<Directory>().isEmpty,
          ),
          throwsA(isA<DocumentOperationSuperseded>()),
        );
        expect(await file.readAsBytes(), before);
        expect(directory.listSync().whereType<Directory>(), isEmpty);
      },
    );
  });

  group('operation ordering', () {
    late _ControlledPersistence persistence;
    late DocumentSession session;

    setUp(() {
      persistence = _ControlledPersistence();
      session = DocumentSession(_project('initial'), persistence: persistence);
    });
    tearDown(() => session.dispose());

    test(
      'later open wins when same-ID documents finish in reverse order',
      () async {
        final first = session.open();
        final second = session.open();
        persistence.loads[1].complete(LoadedProject(_project('second')));
        expect(await second, DocumentIoResult.opened);
        final id = session.sessionId;
        persistence.loads[0].complete(LoadedProject(_project('first')));
        expect(await first, DocumentIoResult.superseded);
        expect(session.project.name, 'second');
        expect(session.sessionId, id);
      },
    );

    test('edits while opening protect the edited document', () async {
      final opening = session.open();
      session.engine.execute([const RenameProject('edited')]);
      persistence.loads.single.complete(LoadedProject(_project('loaded')));
      expect(await opening, DocumentIoResult.superseded);
      expect(session.project.name, 'edited');
    });

    test('invalid candidate cannot partially replace the engine', () async {
      final original = session.workingCopy;
      final opening = session.open();
      persistence.loads.single.complete(
        LoadedProject(_project('broken').copyWith(pages: [])),
      );
      await expectLater(opening, throwsA(isA<EcadException>()));
      expect(session.project, same(original.project));
      expect(session.sessionId, original.sessionId);
      expect(session.savedRevision, original.savedRevision);
    });

    test('imported documents have no file target and remain unsaved', () async {
      final imported = _project('imported');
      expect(
        await session.open(importProject: () async => imported),
        DocumentIoResult.opened,
      );
      expect(session.project, same(imported));
      expect(session.currentFile, isNull);
      expect(session.fileName, isNull);
      expect(session.savedRevision, isNull);
      expect(session.dirty, isTrue);
    });

    test(
      'late save success and failure cannot change a replacement session',
      () async {
        final saving = session.save();
        session.replace(_project('replacement'));
        expect(persistence.saves.single.canCommit(), isFalse);
        persistence.saves.single.result.complete(_savedFile);
        expect(await saving, DocumentIoResult.superseded);
        expect(session.currentFile, isNull);
        expect(session.savedRevision, isNull);
        final failing = session.save();
        session.replace(_project('next replacement'));
        persistence.saves.last.result.completeError(StateError('old failure'));
        expect(await failing, DocumentIoResult.superseded);
        expect(session.project.name, 'next replacement');
        expect(session.savedRevision, isNull);
      },
    );

    test(
      'save records only the snapshot revision when editing continues',
      () async {
        final saving = session.save();
        session.engine.execute([const RenameProject('edited during save')]);
        persistence.saves.single.result.complete(_savedFile);
        expect(await saving, DocumentIoResult.saved);
        expect(session.currentFile, _savedFile.origin);
        expect(session.savedRevision, 0);
        expect(session.dirty, isTrue);
        expect(persistence.saves.single.snapshot.name, 'initial');
      },
    );

    test(
      'two saves cannot commit an older snapshot after a newer save',
      () async {
        final older = session.save();
        session.engine.execute([const RenameProject('newer')]);
        final newer = session.save();
        persistence.saves[1].result.complete(_savedFile);
        expect(await newer, DocumentIoResult.saved);
        expect(persistence.saves[0].canCommit(), isFalse);
        persistence.saves[0].result.complete(
          const SavedProjectFile(name: 'old'),
        );
        expect(await older, DocumentIoResult.superseded);
        expect(session.fileName, _savedFile.origin!.path);
        expect(session.savedRevision, 1);
      },
    );

    test(
      'disposed session rejects pending open and save completions',
      () async {
        final opening = session.open();
        final saving = session.save();
        session.dispose();
        persistence.loads.single.complete(LoadedProject(_project('loaded')));
        persistence.saves.single.result.complete(_savedFile);
        expect(await opening, DocumentIoResult.superseded);
        expect(await saving, DocumentIoResult.superseded);
        expect(session.project.name, 'initial');
        expect(session.fileName, isNull);
      },
    );

    test('download saves never establish a native path', () async {
      final saving = session.save();
      persistence.saves.single.result.complete(
        const SavedProjectFile(name: 'download.oecad'),
      );
      expect(await saving, DocumentIoResult.saved);
      expect(session.currentFile, isNull);
      expect(session.fileName, 'download.oecad');
      final second = session.save();
      expect(persistence.saves.last.target, isNull);
      persistence.saves.last.result.complete(null);
      expect(await second, DocumentIoResult.canceled);
    });
  });
}
