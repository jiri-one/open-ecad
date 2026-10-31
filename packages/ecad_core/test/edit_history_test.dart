// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:ecad_core/ecad_core.dart';
import 'package:test/test.dart';

const _a = 'A · Přejmenování projektu';
const _b = 'B · Popis projektu a listu';
const _c = 'C · Přidání listu';

ProjectEngine _engine({int revision = 0, int historyLimit = 100}) =>
    ProjectEngine(
      EcadProject(
        id: 'synthetic_project',
        name: 'Výchozí projekt',
        revision: revision,
        pages: [Sheet(id: 'sheet', name: 'Výchozí list', number: '1')],
      ),
      historyLimit: historyLimit,
    );

void _editABC(ProjectEngine engine) {
  engine.execute([const RenameProject('Projekt A')], label: _a);
  engine.execute([
    const SetProjectDescription('Popis B'),
    UpdateSheet(engine.project.pages.single.copyWith(name: 'List B')),
  ], label: _b);
  engine.execute([
    AddSheet(Sheet(id: 'second_sheet', name: 'List C', number: '2')),
  ], label: _c);
}

Map<String, Object?> _content(EcadProject project) =>
    project.toJson()..remove('revision');

List<(String, int)> _entries(List<EditHistoryEntry> history) => [
  for (final entry in history) (entry.label, entry.steps),
];

void _expectHistory(
  ProjectEngine engine, {
  required List<String> undo,
  required List<String> redo,
}) {
  expect(_entries(engine.undoHistory), [
    for (final (index, label) in undo.indexed) (label, index + 1),
  ]);
  expect(_entries(engine.redoHistory), [
    for (final (index, label) in redo.indexed) (label, index + 1),
  ]);
  expect(engine.canUndo, undo.isNotEmpty);
  expect(engine.canRedo, redo.isNotEmpty);
  expect(engine.undoLabel, undo.firstOrNull);
  expect(engine.redoLabel, redo.firstOrNull);
}

void _expectRejected(
  ProjectEngine engine,
  void Function() operation,
  String code,
) {
  final project = engine.project;
  final undo = _entries(engine.undoHistory);
  final redo = _entries(engine.redoHistory);
  expect(
    operation,
    throwsA(isA<EcadException>().having((e) => e.code, 'code', code)),
  );
  expect(engine.project, same(project));
  expect(_entries(engine.undoHistory), undo);
  expect(_entries(engine.redoHistory), redo);
  expect(engine.undoLabel, undo.firstOrNull?.$1);
  expect(engine.redoLabel, redo.firstOrNull?.$1);
}

void main() {
  test('empty history has no imaginary origin or actions', () {
    final engine = _engine(revision: 37);
    final original = engine.project;
    _expectHistory(engine, undo: [], redo: []);
    expect(engine.undo(), isFalse);
    expect(engine.redo(), isFalse);
    expect(engine.project, same(original));
    _expectRejected(engine, () => engine.undoSteps(1), 'invalid_history_count');
    _expectRejected(engine, () => engine.redoSteps(1), 'invalid_history_count');
  });

  test(
    'single undo and redo retain real transaction names in next-first order',
    () {
      final engine = _engine();
      _editABC(engine);
      _expectHistory(engine, undo: [_c, _b, _a], redo: []);
      expect(engine.project.revision, 3);

      expect(engine.undo(), isTrue);
      expect(engine.project.pages, hasLength(1));
      _expectHistory(engine, undo: [_b, _a], redo: [_c]);

      expect(engine.undo(), isTrue);
      expect(engine.project.revision, 5);
      expect(engine.project.name, 'Projekt A');
      expect(engine.project.description, isEmpty);
      expect(engine.project.pages.single.name, 'Výchozí list');
      _expectHistory(engine, undo: [_a], redo: [_b, _c]);

      expect(engine.redo(), isTrue);
      expect(engine.project.revision, 6);
      expect(engine.project.description, 'Popis B');
      expect(engine.project.pages.single.name, 'List B');
      _expectHistory(engine, undo: [_b, _a], redo: [_c]);
    },
  );

  test(
    'multi-step jumps restore full transactions and advance every revision',
    () {
      final engine = _engine();
      final original = _content(engine.project);
      _editABC(engine);
      final edited = _content(engine.project);

      expect(engine.undoSteps(2, expectedRevision: 3), isTrue);
      expect(engine.project.revision, 5);
      expect(engine.project.name, 'Projekt A');
      expect(engine.project.description, isEmpty);
      expect(engine.project.pages.single.name, 'Výchozí list');
      _expectHistory(engine, undo: [_a], redo: [_b, _c]);

      expect(engine.redoSteps(2, expectedRevision: 5), isTrue);
      expect(engine.project.revision, 7);
      expect(_content(engine.project), edited);
      _expectHistory(engine, undo: [_c, _b, _a], redo: []);

      expect(engine.undoSteps(3), isTrue);
      expect(engine.project.revision, 10);
      expect(_content(engine.project), original);
      _expectHistory(engine, undo: [], redo: [_a, _b, _c]);

      expect(engine.redoSteps(3), isTrue);
      expect(engine.project.revision, 13);
      expect(_content(engine.project), edited);
      _expectHistory(engine, undo: [_c, _b, _a], redo: []);
    },
  );

  test(
    'multi-step history remains interchangeable with single-step shortcuts',
    () {
      final engine = _engine();
      _editABC(engine);
      final edited = _content(engine.project);
      engine.undoSteps(3);
      engine.redo();
      expect(engine.project.name, 'Projekt A');
      engine.redo();
      expect(engine.project.description, 'Popis B');
      engine.undo();
      expect(engine.project.description, isEmpty);
      _expectHistory(engine, undo: [_a], redo: [_b, _c]);
      engine.redoSteps(2);
      expect(_content(engine.project), edited);
      expect(engine.project.revision, 11);
    },
  );

  test('history snapshots are immutable and detached from later edits', () {
    final engine = _engine();
    _editABC(engine);
    engine.undo();
    final undo = engine.undoHistory;
    final redo = engine.redoHistory;
    expect(undo.clear, throwsUnsupportedError);
    expect(() => redo.add(undo.first), throwsUnsupportedError);
    expect(() => undo[0] = redo.first, throwsUnsupportedError);
    engine.redo();
    engine.execute([const RenameProject('Další název')], label: 'Další úprava');
    expect(_entries(undo), [(_b, 1), (_a, 2)]);
    expect(_entries(redo), [(_c, 1)]);
    _expectHistory(engine, undo: ['Další úprava', _c, _b, _a], redo: []);
  });

  test('a new branch discards redo while keeping its available ancestors', () {
    final engine = _engine();
    _editABC(engine);
    engine.undoSteps(2);
    engine.execute([const RenameProject('Větev D')], label: 'D · Nový název');
    _expectHistory(engine, undo: ['D · Nový název', _a], redo: []);
    expect(engine.redo(), isFalse);
    engine.undo();
    expect(engine.project.name, 'Projekt A');
    expect(engine.project.description, isEmpty);
    _expectHistory(engine, undo: [_a], redo: ['D · Nový název']);
  });

  test(
    'a failed transaction preserves both stacks and does not create a branch',
    () {
      final engine = _engine();
      _editABC(engine);
      engine.undo();
      _expectRejected(
        engine,
        () => engine.execute([
          const RenameProject('Nedokončená změna'),
          const DeleteSheet('missing_sheet'),
        ], label: 'Odmítnutá transakce'),
        'missing_sheet',
      );
      _expectHistory(engine, undo: [_b, _a], redo: [_c]);
      expect(engine.redo(), isTrue);
      expect(engine.project.name, 'Projekt A');
      expect(engine.project.pages, hasLength(2));
    },
  );

  test(
    'retention bounds the reachable past across undo, redo and branching',
    () {
      final engine = _engine(historyLimit: 2);
      _editABC(engine);
      _expectHistory(engine, undo: [_c, _b], redo: []);
      engine.undoSteps(2);
      expect(engine.project.name, 'Projekt A');
      expect(engine.project.description, isEmpty);
      expect(engine.undo(), isFalse);
      _expectHistory(engine, undo: [], redo: [_b, _c]);
      engine.redoSteps(2);
      engine.execute([const RenameProject('Větev D')], label: 'D');
      _expectHistory(engine, undo: ['D', _c], redo: []);
      engine.undoSteps(2);
      expect(engine.project.description, 'Popis B');
      expect(engine.project.pages, hasLength(1));
      expect(engine.undo(), isFalse);
    },
  );

  test(
    'default retention stays at 100 and the supported upper bound stays 1000',
    () {
      final engine = _engine();
      for (var i = 1; i <= 101; i++) {
        engine.execute([RenameProject('Projekt $i')], label: 'Úprava $i');
      }
      expect(engine.undoHistory, hasLength(100));
      engine.undoSteps(100);
      expect(engine.project.name, 'Projekt 1');
      expect(engine.redoHistory, hasLength(100));
      expect(engine.redoHistory.last.steps, 100);
      expect(_engine(historyLimit: 1000).historyLimit, 1000);
      expect(() => _engine(historyLimit: 1001), throwsA(isA<EcadException>()));
    },
  );

  test('invalid counts never apply partial undo or redo', () {
    final engine = _engine();
    _editABC(engine);
    engine.undo();
    for (final count in [-1, 0, 3, 1001]) {
      _expectRejected(
        engine,
        () => engine.undoSteps(count, expectedRevision: 4),
        'invalid_history_count',
      );
    }
    for (final count in [-1, 0, 2, 1001]) {
      _expectRejected(
        engine,
        () => engine.redoSteps(count, expectedRevision: 4),
        'invalid_history_count',
      );
    }
    expect(engine.redo(), isTrue);
    _expectHistory(engine, undo: [_c, _b, _a], redo: []);
  });

  test(
    'stale positions are rejected even after revisiting the same document data',
    () {
      final engine = _engine();
      _editABC(engine);
      final originalContent = _content(engine.project);
      final revision = engine.project.revision;
      engine.undo();
      _expectRejected(
        engine,
        () => engine.redoSteps(1, expectedRevision: revision),
        'stale_revision',
      );
      engine.redo();
      expect(_content(engine.project), originalContent);
      _expectRejected(
        engine,
        () => engine.undoSteps(2, expectedRevision: revision),
        'stale_revision',
      );
      engine.undoSteps(2, expectedRevision: engine.project.revision);
      expect(engine.project.name, 'Projekt A');
    },
  );

  test('undo checks the full revision budget before touching either stack', () {
    final engine = _engine(revision: ProjectLimits.maxRevision - 4);
    _editABC(engine);
    _expectRejected(engine, () => engine.undoSteps(2), 'limit_exceeded');
    _expectHistory(engine, undo: [_c, _b, _a], redo: []);
    expect(engine.undo(), isTrue);
    expect(engine.project.revision, ProjectLimits.maxRevision);
    expect(engine.project.pages, hasLength(1));
    _expectRejected(engine, engine.undo, 'limit_exceeded');
    _expectRejected(engine, engine.redo, 'limit_exceeded');
  });

  test('redo checks the full revision budget before touching either stack', () {
    final engine = _engine(revision: ProjectLimits.maxRevision - 7);
    _editABC(engine);
    engine.undoSteps(3);
    _expectRejected(engine, () => engine.redoSteps(2), 'limit_exceeded');
    _expectHistory(engine, undo: [], redo: [_a, _b, _c]);
    expect(engine.redo(), isTrue);
    expect(engine.project.revision, ProjectLimits.maxRevision);
    expect(engine.project.name, 'Projekt A');
    expect(engine.project.description, isEmpty);
    _expectRejected(engine, engine.undo, 'limit_exceeded');
    _expectRejected(engine, engine.redo, 'limit_exceeded');
    final empty = _engine(revision: ProjectLimits.maxRevision);
    expect(empty.undo(), isFalse);
    expect(empty.redo(), isFalse);
  });

  test(
    'opening a serialized document starts a new history at its current state',
    () {
      final engine = _engine();
      _editABC(engine);
      engine.undo();
      final reopened = ProjectEngine(
        EcadProject.fromJson(engine.project.toJson()),
      );
      expect(reopened.project.toJson(), engine.project.toJson());
      _expectHistory(reopened, undo: [], redo: []);
      reopened.execute([
        const RenameProject('Nová relace'),
      ], label: 'Nová úprava');
      _expectHistory(reopened, undo: ['Nová úprava'], redo: []);
      reopened.undo();
      expect(_content(reopened.project), _content(engine.project));
      expect(reopened.undo(), isFalse);
    },
  );
}
