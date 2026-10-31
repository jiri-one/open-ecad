// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/widgets/edit_history.dart';

const _a = 'Přejmenování A';
const _b = 'Přejmenování B';
const _c = 'Přejmenování C';

ProjectEngine _engine({int historyLimit = 100}) => ProjectEngine(
  EcadProject(
    id: 'synthetic_project',
    name: 'Výchozí projekt',
    pages: [Sheet(id: 'sheet', name: 'List', number: '1')],
  ),
  historyLimit: historyLimit,
);

void _editABC(ProjectEngine engine) {
  for (final (name, label) in [('A', _a), ('B', _b), ('C', _c)]) {
    engine.execute([RenameProject(name)], label: label);
  }
}

Future<void> _wide(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(1080, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
}

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

Widget _dialogHost({
  required List<EditHistoryEntry> undo,
  required List<EditHistoryEntry> redo,
  required ValueChanged<int> onUndo,
  required ValueChanged<int> onRedo,
  double textScale = 1,
}) => MaterialApp(
  builder:
      (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
  home: Builder(
    builder:
        (context) => Scaffold(
          body: TextButton(
            onPressed:
                () => showEditHistoryDialog(
                  context: context,
                  undoHistory: undo,
                  redoHistory: redo,
                  onUndoSteps: onUndo,
                  onRedoSteps: onRedo,
                ),
            child: const Text('Otevřít historii'),
          ),
        ),
  ),
);

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.text('Otevřít historii'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'named actions show the current state and jump in both directions',
    (tester) async {
      await _wide(tester);
      final engine = _engine();
      _editABC(engine);
      final undoCounts = <int>[];
      final redoCounts = <int>[];
      await tester.pumpWidget(
        _host(
          StatefulBuilder(
            builder: (context, setState) {
              final revision = engine.project.revision;
              return EditHistoryView(
                undoHistory: engine.undoHistory,
                redoHistory: engine.redoHistory,
                onUndoSteps:
                    (count) => setState(() {
                      undoCounts.add(count);
                      engine.undoSteps(count, expectedRevision: revision);
                    }),
                onRedoSteps:
                    (count) => setState(() {
                      redoCounts.add(count);
                      engine.redoSteps(count, expectedRevision: revision);
                    }),
              );
            },
          ),
        ),
      );
      expect(find.text('Aktuální stav'), findsOneWidget);
      expect(find.text('Po akci: $_c'), findsOneWidget);
      expect(find.text('Akce k vrácení'), findsOneWidget);
      expect(find.text('Akce k obnovení'), findsOneWidget);
      expect(find.text(_a), findsOneWidget);
      expect(find.text(_b), findsOneWidget);
      expect(find.text(_c), findsOneWidget);
      expect(find.byTooltip('Vrátit: $_c (Ctrl+Z)'), findsOneWidget);
      expect(find.text('K vrácení: 3 · K obnovení: 0'), findsOneWidget);

      await tester.tap(find.text('Vrátit tyto 2 kroky'));
      await tester.pumpAndSettle();
      expect(undoCounts, [2]);
      expect(engine.project.name, 'A');
      expect(find.text('Po akci: $_a'), findsOneWidget);
      expect(find.text('K vrácení: 1 · K obnovení: 2'), findsOneWidget);
      expect(find.byTooltip('Vrátit: $_a (Ctrl+Z)'), findsOneWidget);
      expect(find.byTooltip('Obnovit: $_b (Ctrl+Y)'), findsOneWidget);

      await tester.tap(find.text('Obnovit tyto 2 kroky'));
      await tester.pumpAndSettle();
      expect(redoCounts, [2]);
      expect(engine.project.name, 'C');
      expect(find.text('Po akci: $_c'), findsOneWidget);
      expect(find.text('Není co obnovit.'), findsOneWidget);
    },
  );

  testWidgets('next-step buttons call only the next operation', (tester) async {
    await _wide(tester);
    final engine = _engine();
    _editABC(engine);
    engine.undo();
    final undo = <int>[];
    final redo = <int>[];
    await tester.pumpWidget(
      _host(
        EditHistoryView(
          undoHistory: engine.undoHistory,
          redoHistory: engine.redoHistory,
          onUndoSteps: undo.add,
          onRedoSteps: redo.add,
        ),
      ),
    );
    await tester.tap(find.byTooltip('Vrátit: $_b (Ctrl+Z)'));
    await tester.tap(find.byTooltip('Obnovit: $_c (Ctrl+Y)'));
    expect(undo, [1]);
    expect(redo, [1]);
  });

  testWidgets('empty history explains its scope and disables both actions', (
    tester,
  ) async {
    await _wide(tester);
    final calls = <int>[];
    await tester.pumpWidget(
      _host(
        EditHistoryView(
          undoHistory: const [],
          redoHistory: const [],
          onUndoSteps: calls.add,
          onRedoSteps: calls.add,
        ),
      ),
    );
    expect(
      find.text('V této relaci zatím nejsou zaznamenané úpravy.'),
      findsOneWidget,
    );
    expect(find.text('Není co vrátit.'), findsOneWidget);
    expect(find.text('Není co obnovit.'), findsOneWidget);
    expect(find.textContaining('úprav v této relaci: 100.'), findsOneWidget);
    expect(
      find.textContaining(
        'Otevření nebo obnova projektu začíná novou historii.',
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining('Nová úprava zruší kroky k obnovení.'),
      findsOneWidget,
    );
    for (final tooltip in [
      'Není co vrátit. (Ctrl+Z)',
      'Není co obnovit. (Ctrl+Y)',
    ]) {
      final button = find.ancestor(
        of: find.byTooltip(tooltip),
        matching: find.byType(IconButton),
      );
      expect(tester.widget<IconButton>(button).onPressed, isNull);
      await tester.tap(button);
    }
    expect(calls, isEmpty);
  });

  testWidgets('history can be shown read-only with disabled callbacks', (
    tester,
  ) async {
    await _wide(tester);
    final engine = _engine();
    _editABC(engine);
    engine.undo();
    final project = engine.project;
    await tester.pumpWidget(
      _host(
        EditHistoryView(
          undoHistory: engine.undoHistory,
          redoHistory: engine.redoHistory,
        ),
      ),
    );
    for (final tile in tester.widgetList<ListTile>(find.byType(ListTile))) {
      expect(tile.enabled, isFalse);
    }
    await tester.tap(find.text('Vrátit tyto 2 kroky'));
    await tester.tap(find.text('Obnovit tento krok'));
    expect(engine.project, same(project));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'the retained boundary is not presented as the original project',
    (tester) async {
      await _wide(tester);
      final engine = _engine(historyLimit: 2);
      _editABC(engine);
      engine.undoSteps(2);
      await tester.pumpWidget(
        _host(
          EditHistoryView(
            undoHistory: engine.undoHistory,
            redoHistory: engine.redoHistory,
            historyLimit: engine.historyLimit,
            onRedoSteps: (_) {},
          ),
        ),
      );
      expect(find.text('Nejstarší dostupný stav.'), findsOneWidget);
      expect(find.text(_a), findsNothing);
      expect(find.text(_b), findsOneWidget);
      expect(find.text(_c), findsOneWidget);
      expect(find.textContaining('úprav v této relaci: 2.'), findsOneWidget);
      expect(
        find.textContaining('Starší kroky nad tento limit nejsou dostupné.'),
        findsOneWidget,
      );
    },
  );

  testWidgets('fresh session and a new edit replace the displayed history', (
    tester,
  ) async {
    await _wide(tester);
    final engine = _engine();
    _editABC(engine);
    engine.undoSteps(2);
    Future<void> show(ProjectEngine source) => tester.pumpWidget(
      _host(
        EditHistoryView(
          undoHistory: source.undoHistory,
          redoHistory: source.redoHistory,
        ),
      ),
    );
    await show(engine);
    expect(find.text(_b), findsOneWidget);
    engine.execute([const RenameProject('D')], label: 'Nová větev');
    await show(engine);
    expect(find.text('Nová větev'), findsOneWidget);
    expect(find.text(_b), findsNothing);
    expect(find.text(_c), findsNothing);
    expect(find.text('Není co obnovit.'), findsOneWidget);
    await show(ProjectEngine(engine.project));
    expect(find.text('Nová větev'), findsNothing);
    expect(find.text('K vrácení: 0 · K obnovení: 0'), findsOneWidget);
  });

  testWidgets(
    'blank labels remain selectable without inventing a transaction name',
    (tester) async {
      await _wide(tester);
      final calls = <int>[];
      await tester.pumpWidget(
        _host(
          EditHistoryView(
            undoHistory: const [EditHistoryEntry(label: '  ', steps: 1)],
            redoHistory: const [],
            onUndoSteps: calls.add,
          ),
        ),
      );
      expect(find.text('Úprava bez názvu'), findsOneWidget);
      await tester.tap(find.text('Vrátit tento krok'));
      expect(calls, [1]);
    },
  );

  testWidgets('a thousand retained actions can be scrolled and targeted', (
    tester,
  ) async {
    await _wide(tester);
    final calls = <int>[];
    await tester.pumpWidget(
      _host(
        EditHistoryView(
          undoHistory: [
            for (var step = 1; step <= 1000; step++)
              EditHistoryEntry(label: 'Úprava $step', steps: step),
          ],
          redoHistory: const [],
          historyLimit: 1000,
          onUndoSteps: calls.add,
        ),
      ),
    );
    expect(find.text('Úprava 1000'), findsNothing);
    final scrollable = find.descendant(
      of: find.byKey(const ValueKey('edit-history-undo')),
      matching: find.byType(Scrollable),
    );
    await tester.scrollUntilVisible(
      find.text('Vrátit těchto 1000 kroků'),
      12000,
      scrollable: scrollable,
      maxScrolls: 20,
    );
    await tester.tap(find.text('Vrátit těchto 1000 kroků'));
    expect(calls, [1000]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dialog selects once and closes before returning to its caller', (
    tester,
  ) async {
    await _wide(tester);
    final engine = _engine();
    _editABC(engine);
    final revision = engine.project.revision;
    final counts = <int>[];
    await tester.pumpWidget(
      _dialogHost(
        undo: engine.undoHistory,
        redo: engine.redoHistory,
        onUndo: (count) {
          counts.add(count);
          engine.undoSteps(count, expectedRevision: revision);
        },
        onRedo: (_) => fail('Unexpected redo'),
      ),
    );
    await _open(tester);
    await tester.ensureVisible(find.text('Vrátit tyto 3 kroky'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Vrátit tyto 3 kroky'));
    await tester.pumpAndSettle();
    expect(counts, [3]);
    expect(engine.project.name, 'Výchozí projekt');
    expect(find.byType(EditHistoryView), findsNothing);
    expect(find.text('Otevřít historii'), findsOneWidget);
  });

  testWidgets(
    'dialog preserves its snapshot and lets the owner reject stale positions',
    (tester) async {
      await _wide(tester);
      final engine = _engine();
      _editABC(engine);
      final revision = engine.project.revision;
      final undo = [...engine.undoHistory];
      String? rejectedCode;
      await tester.pumpWidget(
        _dialogHost(
          undo: undo,
          redo: engine.redoHistory,
          onUndo: (count) {
            try {
              engine.undoSteps(count, expectedRevision: revision);
            } on EcadException catch (error) {
              rejectedCode = error.code;
            }
          },
          onRedo: (_) => fail('Unexpected redo'),
        ),
      );
      await _open(tester);
      undo.clear();
      engine.execute([const RenameProject('D')], label: 'Další úprava');
      final current = engine.project;
      await tester.pump();
      expect(find.text(_c), findsOneWidget);
      await tester.tap(find.text('Vrátit tyto 2 kroky'));
      await tester.pumpAndSettle();
      expect(rejectedCode, 'stale_revision');
      expect(engine.project, same(current));
      expect(find.byType(EditHistoryView), findsNothing);
    },
  );

  testWidgets('closing or dismissing history calls neither direction', (
    tester,
  ) async {
    await _wide(tester);
    final engine = _engine();
    _editABC(engine);
    final calls = <int>[];
    await tester.pumpWidget(
      _dialogHost(
        undo: engine.undoHistory,
        redo: engine.redoHistory,
        onUndo: calls.add,
        onRedo: calls.add,
      ),
    );
    await _open(tester);
    await tester.tap(find.text('Zavřít'));
    await tester.pumpAndSettle();
    expect(find.byType(EditHistoryView), findsNothing);
    await _open(tester);
    await tester.tapAt(const Offset(1, 1));
    await tester.pumpAndSettle();
    expect(find.byType(EditHistoryView), findsNothing);
    expect(calls, isEmpty);
  });

  testWidgets(
    'narrow dialog supports enlarged text and long transaction names',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _dialogHost(
          undo: [EditHistoryEntry(label: 'Dlouhá úprava ' * 12, steps: 1)],
          redo: const [EditHistoryEntry(label: 'Obnovení změny', steps: 1)],
          onUndo: (_) {},
          onRedo: (_) {},
          textScale: 2,
        ),
      );
      await _open(tester);
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        find.text('Akce k obnovení'),
        250,
        scrollable:
            find
                .descendant(
                  of: find.byKey(const ValueKey('edit-history-scroll')),
                  matching: find.byType(Scrollable),
                )
                .first,
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Zavřít'));
      await tester.pumpAndSettle();
      expect(find.byType(EditHistoryView), findsNothing);
    },
  );
}
