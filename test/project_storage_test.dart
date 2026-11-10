// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/services/project_persistence.dart';
import 'package:open_ecad/services/project_storage.dart';
import 'package:open_ecad/services/project_storage_native.dart';
import 'package:open_ecad/services/project_storage_web.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

EcadProject _project(String name, {int revision = 0}) => EcadProject(
  id: 'synthetic-project',
  name: name,
  revision: revision,
  pages: [Sheet(id: 'sheet', name: 'Sheet', number: '01')],
);

String _record(String token) => jsonEncode({'storageToken': token});

String _legacy(String id) => jsonEncode({
  'version': 1,
  'sessionId': id,
  'project': _project('legacy').toJson(),
  'savedRevision': 0,
  'fileName': 'import.oecad',
});

class _PlatformStore extends InMemorySharedPreferencesStore {
  _PlatformStore() : super.empty();
  bool failIndex = false;
  bool throwIndex = false;
  bool failRecord = false;
  bool failStartup = false;

  @override
  Future<bool> setValue(String valueType, String key, Object value) {
    if (key == 'flutter.${PreferencesProjectStorage.indexKey}') {
      if (throwIndex) throw StateError('Synthetic index failure');
      if (failIndex) return Future.value(false);
    } else if (key == 'flutter.${ProjectPersistence.startupProjectKey}') {
      if (failStartup) throw StateError('Synthetic metadata failure');
    } else if (failRecord) {
      return Future.value(false);
    }
    return super.setValue(valueType, key, value);
  }
}

class _CapturedFiles implements ProjectFiles {
  Uint8List? savedBytes;
  Iterable<String> Function()? guard;
  @override
  Future<ProjectFileData?> pick() async => null;
  @override
  Future<ProjectFileData> readPath(String path) => throw UnimplementedError();
  @override
  Future<SavedProjectFile?> save(
    Uint8List bytes, {
    required String suggestedName,
    required bool Function() canCommit,
    DocumentFileHandle? target,
    DocumentFileHandle? currentFile,
    Iterable<String> Function()? protectedPaths,
  }) async {
    savedBytes = bytes;
    guard = protectedPaths;
    return SavedProjectFile(name: suggestedName, origin: target);
  }
}

class _ObservedProject extends EcadProject {
  _ObservedProject({this.observer, List<DrawingElement> graphics = const []})
    : super(
        id: 'synthetic-project',
        name: 'Observed',
        pages: [
          Sheet(id: 'sheet', name: 'Sheet', number: '01', graphics: graphics),
        ],
      );
  final SendPort? observer;
  int encodings = 0;
  @override
  Map<String, Object?> toJson() {
    encodings++;
    observer?.send(Isolate.current.controlPort);
    return super.toJson();
  }
}

class _HeadersOnlyStorage implements ProjectStorage {
  _HeadersOnlyStorage(this.headers);
  final Map<String, String> headers;
  @override
  Future<String?> read(String id) =>
      throw StateError('Payload must not be read');
  @override
  Future<String?> readHeader(String id) async => headers[id];
  @override
  Future<List<String>> list() async => headers.keys.toList();
  @override
  Future<void> write(
    String id,
    String source, {
    required String? expectedToken,
    Uint8List? bytes,
  }) => throw UnimplementedError();
  @override
  Future<void> remove(String id, {required String? expectedToken}) =>
      throw UnimplementedError();
}

class _SizeStorage extends _HeadersOnlyStorage {
  _SizeStorage() : super({});
  int? writtenBytes;
  int writes = 0;
  @override
  Future<void> write(
    String id,
    String source, {
    required String? expectedToken,
    Uint8List? bytes,
  }) async {
    writtenBytes = bytes!.length;
    writes++;
  }
}

(EcadProject, EncodedProject) _limitFixture(Object? _) {
  final persistence = ProjectPersistence();
  EcadProject fixture(String text, int remainder) => _project('limit').copyWith(
    pages: [
      Sheet(
        id: 'sheet',
        name: 'Sheet',
        number: '01',
        graphics: [
          for (var i = 0; i < 2048; i++)
            DrawingElement(
              id: 'text_$i',
              kind: DrawingKind.text,
              position: Vec2.zero,
              width: 10,
              height: 10,
              text: i < remainder ? '${text}x' : text,
            ),
        ],
      ),
    ],
  );
  final overhead = utf8.encode(persistence.encode(fixture('', 0))).length;
  final textBytes = ProjectPersistence.maxFileBytes - overhead;
  final text = 'x' * (textBytes ~/ 2048);
  final project = fixture(text, textBytes % 2048);
  requireValidProject(project);
  final source = persistence.encode(project);
  final bytes = utf8.encode(source);
  return (
    project,
    EncodedProject(
      source: source,
      bytes: bytes,
      hash: sha256.convert(bytes).toString(),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final parent = await Directory(
      '.ai/tests/project-storage',
    ).create(recursive: true);
    directory = await parent.createTemp('storage-test-');
  });
  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    await directory.delete(recursive: true);
  });

  FileProjectStorage native() =>
      FileProjectStorage(directory: () async => directory);

  for (final backend in ['native', 'preferences']) {
    ProjectStorage store() =>
        backend == 'native' ? native() : PreferencesProjectStorage();

    test('$backend rejects a stale writer and stale deletion', () async {
      final first = ProjectPersistence(storage: store());
      final second = ProjectPersistence(storage: store());
      final token = await first.saveWorkingCopy(
        WorkingCopy(_project('initial'), sessionId: 'shared'),
      );
      final stale = (await second.loadAutosave(sessionId: 'shared'))!;
      expect(stale.storageToken, token);
      final newer = await first.saveWorkingCopy(
        WorkingCopy(
          _project('newer', revision: 1),
          sessionId: 'shared',
          storageToken: token,
        ),
      );
      expect(newer, isNot(token));
      await expectLater(
        second.saveWorkingCopy(stale),
        throwsA(isA<ProjectStorageConflict>()),
      );
      await expectLater(
        second.removeWorkingCopy('shared', expectedToken: token),
        throwsA(isA<ProjectStorageConflict>()),
      );
      await expectLater(
        second.removeWorkingCopy('shared', expectedToken: null),
        throwsA(isA<ProjectStorageConflict>()),
      );
      expect(
        (await second.loadAutosave(sessionId: 'shared'))!.project.name,
        'newer',
      );
      await second.removeWorkingCopy('shared', expectedToken: newer);
      expect(await second.listRecoveryIds(), isEmpty);
      await expectLater(
        second.removeWorkingCopy('shared', expectedToken: newer),
        throwsA(isA<ProjectStorageConflict>()),
      );
      await second.removeWorkingCopy('shared', expectedToken: null);
    });

    test('$backend serializes simultaneous writers across instances', () async {
      final first = store(), second = store();
      final results = await Future.wait<Object>([
        first
            .write('race', _record('a'), expectedToken: null)
            .then<Object>((_) => 'a', onError: (Object e) => e),
        second
            .write('race', _record('b'), expectedToken: null)
            .then<Object>((_) => 'b', onError: (Object e) => e),
      ]);
      expect(results.whereType<ProjectStorageConflict>(), hasLength(1));
      final winner = results.whereType<String>().single;
      expect(projectStorageToken(await store().readHeader('race')), winner);
    });

    test('$backend identical snapshots retain their content token', () async {
      final persistence = ProjectPersistence(storage: store());
      final project = _project('unchanged');
      final token = await persistence.saveWorkingCopy(
        WorkingCopy(project, sessionId: 'clean', savedRevision: 0),
      );
      final copy = (await persistence.loadAutosave(sessionId: 'clean'))!;
      expect(await persistence.saveWorkingCopy(copy), token);
      expect(await persistence.saveWorkingCopy(copy), token);
      final metadataChange = await persistence.saveWorkingCopy(
        WorkingCopy(
          project,
          sessionId: 'clean',
          savedRevision: 0,
          fileName: 'copy.oecad',
          storageToken: token,
        ),
      );
      expect(metadataChange, isNot(token));
      expect(
        (await persistence.loadProjectSummary('clean'))!.storageToken,
        metadataChange,
      );
    });
  }

  test(
    'native writes honor a lock held by another process and recheck its commit',
    () async {
      final store = native();
      await store.write('locked', _record('initial'), expectedToken: null);
      final process = await Process.start('python3', [
        '-u',
        '-c',
        '''
import fcntl, os, sys
with open(sys.argv[1], 'a') as lock:
    fcntl.lockf(lock, fcntl.LOCK_EX)
    print('locked', flush=True)
    source = sys.stdin.readline()
    if source:
        with open(sys.argv[2] + '.staging', 'w') as output:
            output.write(source)
            output.flush()
            os.fsync(output.fileno())
        os.replace(sys.argv[2] + '.staging', sys.argv[2])
''',
        '${directory.path}/locked.json.lock',
        '${directory.path}/locked.json',
      ]);
      addTearDown(() {
        process.kill();
      });
      final errors = process.stderr.transform(utf8.decoder).join();
      expect(
        await process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .first,
        'locked',
      );
      var completed = false;
      final result = store
          .write('locked', _record('stale'), expectedToken: 'initial')
          .then<Object>(
            (_) {
              completed = true;
              return 'unexpected success';
            },
            onError: (Object e) {
              completed = true;
              return e;
            },
          );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(completed, isFalse);
      process.stdin.writeln(_record('external'));
      await process.stdin.close();
      expect(await process.exitCode, 0, reason: await errors);
      expect(await result, isA<ProjectStorageConflict>());
      expect(projectStorageToken(await store.readHeader('locked')), 'external');
    },
    skip: !Platform.isLinux,
  );

  test(
    'native uses the supplied bytes and rejects unsafe record ids',
    () async {
      final store = native();
      final bytes = utf8.encode(_record('prepared'));
      await store.write(
        'bytes',
        'unused source',
        expectedToken: null,
        bytes: bytes,
      );
      expect(await store.read('bytes'), utf8.decode(bytes));
      await expectLater(
        store.write('../escape', '{}', expectedToken: null),
        throwsFormatException,
      );
      await expectLater(
        PreferencesProjectStorage().write('index', '{}', expectedToken: null),
        throwsFormatException,
      );
      expect(
        await directory.list().where((entry) => entry is Directory).toList(),
        isEmpty,
      );
    },
  );

  test(
    'native summaries read only the first line even when the payload is unreadable',
    () async {
      final persistence = ProjectPersistence(storage: native());
      final token = await persistence.saveWorkingCopy(
        WorkingCopy(
          _project('Summary', revision: 2),
          sessionId: 'summary',
          savedRevision: 1,
          currentFile: const DocumentFileHandle(
            path: '/synthetic/source.oecad',
            version: 'file-version',
          ),
        ),
      );
      final header = (await native().readHeader('summary'))!;
      expect(header.length, lessThan(1000));
      expect(header, isNot(contains('frameTemplates')));
      await File(
        '${directory.path}/summary.json',
      ).writeAsBytes([...utf8.encode('$header\n'), 0xff]);
      final summary = (await persistence.loadProjectSummary('summary'))!;
      expect(summary.name, 'Summary');
      expect(summary.storageToken, token);
      expect(summary.revision, 2);
      expect(summary.hasPendingFileChanges, isTrue);
      await expectLater(
        persistence.loadAutosave(sessionId: 'summary'),
        throwsA(isA<FileSystemException>()),
      );
    },
  );

  test(
    'legacy preference records survive native adoption and guarded removal',
    () async {
      final legacy = _legacy('legacy');
      SharedPreferences.setMockInitialValues({
        '${PreferencesProjectStorage.prefix}legacy': legacy,
      });
      final persistence = ProjectPersistence(storage: native());
      expect(await persistence.listRecoveryIds(), ['legacy']);
      final copy = (await persistence.loadAutosave(sessionId: 'legacy'))!;
      expect(copy.storageToken, isNull);
      expect((await persistence.loadProjectSummary('legacy'))!.name, 'legacy');
      final token = await persistence.saveWorkingCopy(copy);
      expect(
        (await persistence.loadAutosave(sessionId: 'legacy'))!.storageToken,
        token,
      );
      expect(
        (await SharedPreferences.getInstance()).getString(
          '${PreferencesProjectStorage.prefix}legacy',
        ),
        legacy,
      );
      await expectLater(
        persistence.saveWorkingCopy(copy),
        throwsA(isA<ProjectStorageConflict>()),
      );
      await persistence.removeWorkingCopy('legacy', expectedToken: token);
      expect(await native().read('legacy'), isNull);
      expect(await persistence.listRecoveryIds(), isEmpty);
    },
  );

  test(
    'explicit missing and unsupported older copies do not erase data',
    () async {
      final persistence = ProjectPersistence(
        storage: PreferencesProjectStorage(),
      );
      expect(await persistence.loadAutosave(), isNull);
      await expectLater(
        persistence.loadAutosave(sessionId: 'missing'),
        throwsFormatException,
      );
      expect(await persistence.loadProjectSummary('missing'), isNull);
      SharedPreferences.setMockInitialValues({
        ProjectPersistence.autosaveKey: 'old unsupported data',
      });
      await expectLater(persistence.loadAutosave(), throwsFormatException);
      expect(
        (await SharedPreferences.getInstance()).getString(
          ProjectPersistence.autosaveKey,
        ),
        'old unsupported data',
      );
    },
  );

  test(
    'preferences reload external changes and discover records absent from the index',
    () async {
      final platform = _PlatformStore();
      SharedPreferencesStorePlatform.instance = platform;
      final store = PreferencesProjectStorage();
      expect(await store.list(), isEmpty);
      await platform.setValue(
        'String',
        'flutter.${PreferencesProjectStorage.prefix}external',
        _record('external'),
      );
      await platform.setValue(
        'StringList',
        'flutter.${PreferencesProjectStorage.indexKey}',
        ['ghost'],
      );
      await platform.setValue(
        'Bool',
        'flutter.${PreferencesProjectStorage.prefix}unrelated',
        true,
      );
      await store.write('mine', _record('mine'), expectedToken: null);
      expect(await store.list(), ['mine', 'external']);
      expect(await store.read('external'), _record('external'));
      await platform.setValue(
        'String',
        'flutter.${PreferencesProjectStorage.prefix}external',
        _record('newer'),
      );
      expect(projectStorageToken(await store.readHeader('external')), 'newer');
      await expectLater(
        store.write('external', _record('old'), expectedToken: 'external'),
        throwsA(isA<ProjectStorageConflict>()),
      );
    },
  );

  for (final throwsIndex in [false, true]) {
    test(
      'index failure ($throwsIndex) cannot revoke a committed token or prevent discovery',
      () async {
        final platform =
            _PlatformStore()
              ..failIndex = !throwsIndex
              ..throwIndex = throwsIndex;
        SharedPreferencesStorePlatform.instance = platform;
        final persistence = ProjectPersistence(
          storage: PreferencesProjectStorage(),
        );
        final token = await persistence.saveWorkingCopy(
          WorkingCopy(_project('kept'), sessionId: 'kept'),
        );
        expect(await persistence.listRecoveryIds(), ['kept']);
        expect(
          (await persistence.loadAutosave(sessionId: 'kept'))!.storageToken,
          token,
        );
        await persistence.removeWorkingCopy('kept', expectedToken: token);
        expect(await persistence.listRecoveryIds(), isEmpty);
      },
    );
  }

  test(
    'failed primary preference writes are not returned from the stale cache',
    () async {
      final platform = _PlatformStore();
      SharedPreferencesStorePlatform.instance = platform;
      final store = PreferencesProjectStorage();
      await store.write('kept', _record('before'), expectedToken: null);
      platform.failRecord = true;
      await expectLater(
        store.write('kept', _record('failed'), expectedToken: 'before'),
        throwsStateError,
      );
      expect(await store.read('kept'), _record('before'));
      platform.failRecord = false;
      await store.write('kept', _record('retry'), expectedToken: 'before');
      expect(await store.read('kept'), _record('retry'));
    },
  );

  test(
    'one prepared canonical encoding is reused by checkpoint and source saves',
    () async {
      final files = _CapturedFiles();
      final store = PreferencesProjectStorage();
      final persistence = ProjectPersistence(storage: store, files: files);
      final project = _ObservedProject();
      final prepared = await persistence.prepareProject(project);
      expect(prepared.hash, sha256.convert(prepared.bytes).toString());
      expect(utf8.decode(prepared.bytes), prepared.source);
      await persistence.saveWorkingCopy(
        WorkingCopy(project, sessionId: 'prepared'),
        encoded: prepared,
      );
      final saved = (await store.read('prepared'))!;
      expect(jsonDecode(saved)['project'], jsonDecode(prepared.source));
      await persistence.saveTo(
        project,
        const DocumentFileHandle(
          path: '/synthetic/source.oecad',
          version: 'version',
        ),
        canCommit: () => true,
        encoded: prepared,
      );
      expect(identical(files.savedBytes, prepared.bytes), isTrue);
      final paths = <String>['/synthetic/a.oecad'];
      await persistence.saveAs(
        project,
        canCommit: () => true,
        encoded: prepared,
        protectedPaths: () => paths,
      );
      paths.add('/synthetic/b.oecad');
      expect(files.guard!(), paths);
      expect(project.encodings, 1);
    },
  );

  test(
    'the 128 MiB limit applies to the payload without charging envelope overhead',
    () async {
      final (project, encoded) = await compute(_limitFixture, null);
      expect(encoded.bytes.length, ProjectPersistence.maxFileBytes);
      final store = _SizeStorage();
      final persistence = ProjectPersistence(storage: store);
      await persistence.saveWorkingCopy(
        WorkingCopy(project, sessionId: 'limit'),
        encoded: encoded,
      );
      expect(store.writtenBytes, greaterThan(ProjectPersistence.maxFileBytes));
      await expectLater(
        persistence.saveWorkingCopy(
          WorkingCopy(project, sessionId: 'limit'),
          encoded: EncodedProject(
            source: '',
            bytes: Uint8List(ProjectPersistence.maxFileBytes + 1),
            hash: '',
          ),
        ),
        throwsA(isA<AutosaveTooLargeException>()),
      );
      expect(store.writes, 1);
    },
  );

  test(
    'project hashes ignore map insertion order and matching uses headers only',
    () async {
      final store = PreferencesProjectStorage();
      final persistence = ProjectPersistence(storage: store);
      final a = _project(
        'import',
      ).copyWith(documentFields: {'title': 'A', 'author': 'B'});
      final b = _project(
        'import',
      ).copyWith(documentFields: {'author': 'B', 'title': 'A'});
      final encoded = await persistence.prepareProject(a);
      expect((await persistence.prepareProject(b)).hash, encoded.hash);
      expect(await persistence.projectsMatch(a, b), isTrue);
      expect(
        await persistence.projectsMatch(a, b.copyWith(name: 'different')),
        isFalse,
      );
      await persistence.saveWorkingCopy(
        WorkingCopy(a, sessionId: 'imported', fileName: 'import.oecad'),
        encoded: encoded,
      );
      await persistence.saveWorkingCopy(
        WorkingCopy(
          a,
          sessionId: 'native',
          fileName: 'native.oecad',
          currentFile: const DocumentFileHandle(
            path: '/synthetic/native.oecad',
            version: 'version',
          ),
        ),
        encoded: encoded,
      );
      final headers = _HeadersOnlyStorage({
        'broken': '{invalid',
        'imported': (await store.readHeader('imported'))!,
        'native': (await store.readHeader('native'))!,
      });
      final listing = ProjectPersistence(storage: headers);
      expect(
        (await listing.findMatchingLocalProject(
          fileName: 'import.oecad',
          projectHash: encoded.hash,
        ))!.sessionId,
        'imported',
      );
      expect(
        await listing.findMatchingLocalProject(
          fileName: 'different.oecad',
          projectHash: encoded.hash,
        ),
        isNull,
      );
      expect(
        await listing.findMatchingLocalProject(
          fileName: 'import.oecad',
          projectHash: 'different',
        ),
        isNull,
      );
      expect(
        await listing.findMatchingLocalProject(
          fileName: 'native.oecad',
          projectHash: encoded.hash,
        ),
        isNull,
      );
    },
  );

  for (final kind in ['tiny', 'text', 'paths']) {
    test(
      '$kind encoding uses the appropriate isolate and restores valid models',
      () async {
        final observer = ReceivePort();
        addTearDown(observer.close);
        final graphics = <DrawingElement>[
          if (kind == 'text')
            for (var i = 0; i < 40; i++)
              DrawingElement(
                id: 'text_$i',
                kind: DrawingKind.text,
                position: Vec2.zero,
                width: 10,
                height: 10,
                text: 'x' * 4096,
              ),
          if (kind == 'paths')
            for (var i = 0; i < 100; i++)
              DrawingElement(
                id: 'path_$i',
                kind: DrawingKind.path,
                position: Vec2.zero,
                width: 10,
                height: 10,
                path: [
                  PathSegment(verb: PathVerb.moveTo, points: const [Vec2.zero]),
                  for (var j = 1; j < 32; j++)
                    PathSegment(
                      verb: PathVerb.lineTo,
                      points: [Vec2(j.toDouble(), 1)],
                    ),
                ],
              ),
        ];
        final project = _ObservedProject(
          observer: observer.sendPort,
          graphics: graphics,
        );
        final persistence = ProjectPersistence(storage: native());
        final prepared = await persistence.prepareProject(project);
        expect(
          await observer.first,
          kind == 'tiny'
              ? Isolate.current.controlPort
              : isNot(Isolate.current.controlPort),
        );
        final token = await persistence.saveWorkingCopy(
          WorkingCopy(project, sessionId: kind),
          encoded: prepared,
        );
        final restored = (await persistence.loadAutosave(sessionId: kind))!;
        expect(restored.storageToken, token);
        expect(
          await persistence.projectsMatch(project, restored.project),
          isTrue,
        );
        final engine = await persistence.prepareEngine(restored.project);
        expect(
          engine.project.pages.single.graphics,
          hasLength(graphics.length),
        );
        expect(engine.canUndo, isFalse);
      },
    );
  }

  testWidgets('tiny preparation completes without a background event loop', (
    tester,
  ) async {
    final persistence = ProjectPersistence(
      storage: PreferencesProjectStorage(),
    );
    final project = _project('tiny');
    var done = false;
    persistence
        .prepareProject(project)
        .then((_) => persistence.prepareEngine(project))
        .then((_) {
          done = true;
        });
    await tester.pump();
    expect(done, isTrue);
  });

  test('file session ids fold Windows case but preserve Linux case', () {
    final persistence = ProjectPersistence();
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final windows = persistence.fileSessionId(r'C:\Synthetic\Source.oecad');
    expect(windows, persistence.fileSessionId('c:/synthetic/source.oecad'));
    expect(windows, matches(RegExp(r'^file_[a-f0-9]{64}$')));
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    expect(
      persistence.fileSessionId('/Synthetic/Source.oecad'),
      isNot(persistence.fileSessionId('/synthetic/source.oecad')),
    );
  });

  test(
    'startup metadata reloads and failures never block a saved close',
    () async {
      final platform = _PlatformStore();
      SharedPreferencesStorePlatform.instance = platform;
      final persistence = ProjectPersistence();
      await persistence.rememberStartupProject(
        'active',
        filePath: '/synthetic/source.oecad',
      );
      expect(await persistence.loadStartupProject(), (
        sessionId: 'active',
        filePath: '/synthetic/source.oecad',
      ));
      platform.failStartup = true;
      await persistence.rememberStartupProject('failed');
      expect((await persistence.loadStartupProject())!.sessionId, 'active');
      platform.failStartup = false;
      await platform.setValue(
        'String',
        'flutter.${ProjectPersistence.startupProjectKey}',
        '{invalid',
      );
      expect(await persistence.loadStartupProject(), isNull);
    },
  );
}
