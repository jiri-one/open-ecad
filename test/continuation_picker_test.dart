import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/widgets/continuation_editor.dart';
import 'package:open_ecad/widgets/continuation_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'continuation_fixtures.dart';

final _search = find.byKey(const ValueKey('continuation-picker-search'));
final _list = find.byKey(const ValueKey('continuation-picker-list'));
final _count = find.byKey(const ValueKey('continuation-picker-count'));
final _error = find.byKey(const ValueKey('continuation-picker-error'));

class _Result<T> {
  bool done = false;
  T? value;
}

Future<_Result<T>> _open<T>(
  WidgetTester tester,
  Future<T?> Function(BuildContext) show,
) async {
  tester.view.physicalSize = const Size(1100, 850);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final result = _Result<T>();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder:
              (context) => TextButton(
                onPressed: () async {
                  result.value = await show(context);
                  result.done = true;
                },
                child: const Text('Open'),
              ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
  return result;
}

Future<void> _type(WidgetTester tester, String query) async {
  await tester.enterText(_search, query);
  await tester.pumpAndSettle();
}

Future<void> _key(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pumpAndSettle();
}

Finder _link(String id, String? sheet) =>
    find.byKey(ValueKey(('continuation-picker-link', id, sheet)));
Finder _sheet(String id) =>
    find.byKey(ValueKey(('continuation-picker-sheet', id)));
Finder _target(String sheet, String marker) =>
    find.byKey(ValueKey(('continuation-target', sheet, marker)));

class _MetadataSheet extends Sheet {
  _MetadataSheet({
    required super.id,
    required super.name,
    required super.number,
    super.structure,
    super.continuations,
  });
  int markerReads = 0;
  int structureReads = 0;
  @override
  List<ContinuationMarker> get continuations {
    markerReads++;
    return super.continuations;
  }

  @override
  StructureContext get structure {
    structureReads++;
    return super.structure;
  }

  @override
  List<DrawingElement> get graphics => throw StateError('Picker read graphics');
  @override
  List<Device> get devices => throw StateError('Picker read devices');
  @override
  List<Wire> get wires => throw StateError('Picker read connectivity');
}

EcadProject _largeProject() => EcadProject(
  id: 'synthetic-large',
  name: 'Synthetic picker metadata',
  continuationLinks: [
    for (var i = 0; i < 1200; i++)
      ContinuationLink(
        id: 'link-$i',
        label: i >= 1198 ? 'Duplicated signal' : 'Signal $i',
      ),
    const ContinuationLink(id: 'orphan', label: 'Unplaced signal'),
  ],
  pages: [
    for (var s = 0; s < 20; s++)
      _MetadataSheet(
        id: 'sheet-$s',
        number: '01',
        name: 'Sheet $s',
        structure: StructureContext(
          functionPath: ['AREA/$s'],
          locationPath: ['CAB.$s'],
          productPath: ['UNIT$s'],
        ),
        continuations: [
          for (var i = s * 60; i < (s + 1) * 60; i++)
            ContinuationMarker(
              id: 'marker-$i',
              linkId: 'link-$i',
              position: Vec2(i.toDouble(), 10),
            ),
          if (s == 19)
            const ContinuationMarker(
              id: 'other-context',
              linkId: 'link-0',
              position: Vec2(0, 0),
            ),
        ],
      ),
  ],
);

EcadProject _smallProject() => EcadProject(
  id: 'small',
  name: 'Synthetic structure',
  continuationLinks: const [
    ContinuationLink(id: 'network-a', label: 'Řízení'),
    ContinuationLink(id: 'network-b', label: 'Řízení'),
    ContinuationLink(id: 'unplaced', label: 'Orphan'),
  ],
  pages: [
    Sheet(
      id: 'atomic',
      number: '01',
      name: 'Atomic page',
      structure: StructureContext(
        functionPath: ['A/B'],
        locationPath: ['K.L'],
        productPath: ['PRODUCT'],
      ),
      continuations: const [
        ContinuationMarker(
          id: 'm-a',
          linkId: 'network-a',
          position: Vec2(1, 2),
        ),
      ],
    ),
    Sheet(
      id: 'nested',
      number: '01',
      name: 'Nested page',
      structure: StructureContext(
        functionPath: ['A', 'B'],
        locationPath: ['K', 'L'],
      ),
      continuations: const [
        ContinuationMarker(
          id: 'm-b',
          linkId: 'network-b',
          position: Vec2(3, 4),
        ),
      ],
    ),
    Sheet(
      id: 'empty',
      number: '01',
      name: 'Empty structure',
      continuations: const [
        ContinuationMarker(
          id: 'm-c',
          linkId: 'network-a',
          position: Vec2(5, 6),
        ),
      ],
    ),
  ],
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    '1200 networks build only visible rows and reuse metadata while typing',
    (tester) async {
      final project = _largeProject();
      final result = await _open(
        tester,
        (context) => showContinuationLinkPicker(
          context,
          project: project,
          isCurrent: () => true,
        ),
      );
      expect(tester.widget<TextField>(_search).focusNode!.hasFocus, isTrue);
      expect(find.byType(ListTile).evaluate().length, lessThan(30));
      expect(
        tester.widget<Text>(_count).data,
        'Výsledky: 1201 / 1201 · míst: 1202',
      );
      expect(find.text('Signal 0 · link-0'), findsNothing);
      final sheets = project.pages.cast<_MetadataSheet>();
      final reads =
          sheets.map((s) => (s.markerReads, s.structureReads)).toList();
      await _type(tester, 'signal');
      final view = tester.widget<ListView>(_list);
      expect(
        (view.childrenDelegate as SliverChildBuilderDelegate).childCount,
        1202,
      );
      expect(find.byType(ListTile).evaluate().length, lessThan(30));
      expect(_link('link-1197', 'sheet-19'), findsNothing);
      view.controller!.jumpTo(view.controller!.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(find.text('Unplaced signal · orphan'), findsOneWidget);
      expect(find.text('Duplicated signal · link-1199'), findsNothing);
      await _type(tester, 'Duplicated signal');
      expect(tester.widget<Text>(_count).data, 'Výsledky: 2 / 1201');
      expect(_link('link-1198', 'sheet-19'), findsOneWidget);
      expect(_link('link-1199', 'sheet-19'), findsOneWidget);
      await _key(tester, LogicalKeyboardKey.arrowDown);
      expect(
        tester.widget<ListTile>(_link('link-1199', 'sheet-19')).selected,
        isTrue,
      );
      await _key(tester, LogicalKeyboardKey.enter);
      expect(result.value, 'link-1199');
      expect(
        sheets.map((s) => (s.markerReads, s.structureReads)).toList(),
        reads,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'structure tokens find a distant network without expanding branches',
    (tester) async {
      final result = await _open(
        tester,
        (context) => showContinuationLinkPicker(
          context,
          project: _largeProject(),
          isCurrent: () => true,
        ),
      );
      await _type(tester, '=AREA/19 +CAB.19 -UNIT19 link-1199');
      expect(tester.widget<Text>(_count).data, 'Výsledky: 1 / 1201');
      await _key(tester, LogicalKeyboardKey.enter);
      expect(result.value, 'link-1199');
    },
  );

  testWidgets(
    'tree preserves atomic slash/dot codes, expansion and first aspect',
    (tester) async {
      await _open(
        tester,
        (context) => showContinuationSheetPicker(
          context,
          project: _smallProject(),
          isCurrent: () => true,
        ),
      );
      expect(find.text('=A/B'), findsOneWidget);
      expect(find.text('=A'), findsOneWidget);
      expect(find.text('=B'), findsNothing);
      await tester.tap(find.text('=A/B'));
      await tester.pumpAndSettle();
      expect(find.text('+K.L'), findsOneWidget);
      expect(find.text('+K'), findsNothing);
      await _key(tester, LogicalKeyboardKey.arrowLeft);
      expect(find.text('+K.L'), findsNothing);
      await _key(tester, LogicalKeyboardKey.arrowRight);
      expect(find.text('+K.L'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('continuation-picker-aspect')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Nejprve + umístění').last);
      await tester.pumpAndSettle();
      expect(find.text('+K.L'), findsOneWidget);
      expect(find.text('+K'), findsOneWidget);
      expect(find.text('=A/B'), findsNothing);
      await tester.tap(find.text('+K.L'));
      await tester.pumpAndSettle();
      expect(find.text('=A/B'), findsOneWidget);
      await _key(tester, LogicalKeyboardKey.escape);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'current network reveals only its actual path and never merges contexts',
    (tester) async {
      final result = await _open(
        tester,
        (context) => showContinuationLinkPicker(
          context,
          project: _largeProject(),
          currentLinkId: 'link-1199',
          isCurrent: () => true,
        ),
      );
      expect(
        find.text('Aktuální síť: Duplicated signal · link-1199'),
        findsOneWidget,
      );
      expect(_link('link-1199', 'sheet-19'), findsOneWidget);
      expect(find.byType(ListTile).evaluate().length, lessThan(30));
      await _type(tester, 'link-0');
      expect(tester.widget<Text>(_count).data, 'Výsledky: 1 / 1201 · míst: 2');
      expect(_link('link-0', 'sheet-0'), findsOneWidget);
      expect(_link('link-0', 'sheet-19'), findsOneWidget);
      await tester.tap(_link('link-0', 'sheet-19'));
      await tester.pumpAndSettle();
      expect(result.value, 'link-0');
    },
  );

  testWidgets('orphans have their own branch and can be selected', (
    tester,
  ) async {
    final result = await _open(
      tester,
      (context) => showContinuationLinkPicker(
        context,
        project: _smallProject(),
        isCurrent: () => true,
      ),
    );
    await tester.tap(find.text('Bez výskytu'));
    await tester.pumpAndSettle();
    expect(_link('unplaced', null), findsOneWidget);
    await tester.tap(_link('unplaced', null));
    await tester.pumpAndSettle();
    expect(result.value, 'unplaced');
  });

  testWidgets(
    'empty structures are selectable and equal page designations keep IDs',
    (tester) async {
      final project = EcadProject(
        id: 'equal',
        name: 'Equal designations',
        pages: [
          Sheet(id: 'a', name: 'Same', number: '01'),
          Sheet(id: 'b', name: 'Same', number: '01'),
          Sheet(
            id: 'graphic',
            name: 'Same',
            number: '01',
            type: SheetType.form,
          ),
        ],
      );
      final result = await _open(
        tester,
        (context) => showContinuationSheetPicker(
          context,
          project: project,
          isCurrent: () => true,
        ),
      );
      expect(tester.widget<Text>(_count).data, 'Výsledky: 2 / 2');
      await tester.tap(find.text('Bez struktury'));
      await tester.pumpAndSettle();
      expect(_sheet('a'), findsOneWidget);
      expect(_sheet('b'), findsOneWidget);
      expect(_sheet('graphic'), findsNothing);
      await tester.tap(_sheet('b'));
      await tester.pumpAndSettle();
      expect(result.value, 'b');
    },
  );

  testWidgets(
    'search is accent insensitive; full page designation selects a sheet',
    (tester) async {
      final project = _smallProject();
      final result = await _open(
        tester,
        (context) => showContinuationSheetPicker(
          context,
          project: project,
          isCurrent: () => true,
        ),
      );
      await _type(tester, fullPageDesignation(project.pages.first));
      expect(tester.widget<Text>(_count).data, 'Výsledky: 1 / 3');
      await _key(tester, LogicalKeyboardKey.enter);
      expect(result.value, 'atomic');
      final link = await _open(
        tester,
        (context) => showContinuationLinkPicker(
          context,
          project: project,
          isCurrent: () => true,
        ),
      );
      await _type(tester, 'RIZENI +K.L');
      expect(tester.widget<Text>(_count).data, 'Výsledky: 1 / 3');
      await _key(tester, LogicalKeyboardKey.enter);
      expect(link.value, 'network-a');
    },
  );

  testWidgets(
    '1200 target results are lazy and select the exact marker identity',
    (tester) async {
      final page = Sheet(id: 'large-page', name: 'Same target', number: '01');
      final targets = [
        for (var i = 0; i < 1200; i++)
          ContinuationTarget(
            sheet: page,
            marker: ContinuationMarker(
              id: 'target-$i',
              linkId: 'network',
              position: Vec2(i.toDouble(), 10),
            ),
          ),
      ];
      final result = await _open(
        tester,
        (context) => showContinuationTargetPicker(
          context,
          targets: targets,
          linkLabels: {'network': 'Remote signal'},
          isCurrent: () => true,
        ),
      );
      await _type(tester, 'remote signal');
      expect(
        (tester.widget<ListView>(_list).childrenDelegate
                as SliverChildBuilderDelegate)
            .childCount,
        1200,
      );
      expect(find.byType(ListTile).evaluate().length, lessThan(30));
      await _type(tester, 'target-1199');
      expect(_target('large-page', 'target-1199'), findsOneWidget);
      await _key(tester, LogicalKeyboardKey.enter);
      expect(result.value, same(targets.last));
    },
  );

  testWidgets(
    'Tab leaves a long result list in one step and Enter activates the focused action',
    (tester) async {
      final result = await _open(
        tester,
        (context) => showContinuationLinkPicker(
          context,
          project: _largeProject(),
          isCurrent: () => true,
        ),
      );
      await _type(tester, 'signal');
      await _key(tester, LogicalKeyboardKey.tab);
      await _key(tester, LogicalKeyboardKey.tab);
      await _key(tester, LogicalKeyboardKey.tab);
      final newButtonFocus = Focus.of(
        tester.element(find.text('Nová samostatná síť').last),
      );
      expect(newButtonFocus.hasFocus, isTrue);
      await _key(tester, LogicalKeyboardKey.enter);
      expect(result.value, '');
    },
  );

  testWidgets(
    'same marker IDs and page designations in distinct sheets remain distinct targets',
    (tester) async {
      final targets = [
        for (final id in ['first', 'second'])
          ContinuationTarget(
            sheet: Sheet(id: id, name: 'Same', number: '01'),
            marker: const ContinuationMarker(
              id: 'same-marker',
              linkId: 'network',
              position: Vec2(1, 2),
            ),
          ),
      ];
      final result = await _open(
        tester,
        (context) => showContinuationTargetPicker(
          context,
          targets: targets,
          isCurrent: () => true,
        ),
      );
      await _type(tester, 'same-marker');
      expect(tester.widget<Text>(_count).data, 'Výsledky: 2 / 2');
      expect(_target('first', 'same-marker'), findsOneWidget);
      expect(_target('second', 'same-marker'), findsOneWidget);
      await tester.tap(_target('second', 'same-marker'));
      await tester.pumpAndSettle();
      expect(result.value, same(targets.last));
    },
  );

  testWidgets(
    'no matches explain the result and Enter never implicitly creates a network',
    (tester) async {
      final result = await _open(
        tester,
        (context) => showContinuationLinkPicker(
          context,
          project: _smallProject(),
          isCurrent: () => true,
        ),
      );
      await _type(tester, 'not found');
      expect(find.textContaining('Nic neodpovídá hledání.'), findsOneWidget);
      await _key(tester, LogicalKeyboardKey.enter);
      expect(result.done, isFalse);
      await _key(tester, LogicalKeyboardKey.escape);
      expect(result.done, isTrue);
      expect(result.value, isNull);
    },
  );

  testWidgets('empty project offers only an explicit new network choice', (
    tester,
  ) async {
    final result = await _open(
      tester,
      (context) => showContinuationLinkPicker(
        context,
        project: EcadProject(id: 'empty', name: 'Empty', pages: []),
        isCurrent: () => true,
      ),
    );
    expect(find.text('Žádné položky k výběru.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('continuation-picker-new')));
    await tester.pumpAndSettle();
    expect(result.value, '');
    expect(result.done, isTrue);
  });

  for (final kind in ['link', 'sheet', 'target', 'new']) {
    for (final accept in ['click', 'keyboard']) {
      testWidgets('$kind rejects a stale $accept and Escape cancels', (
        tester,
      ) async {
        var current = true;
        final project = _smallProject();
        final target = ContinuationTarget(
          sheet: project.pages.first,
          marker: project.pages.first.continuations.first,
        );
        final result = await _open<Object>(
          tester,
          (context) => switch (kind) {
            'sheet' => showContinuationSheetPicker(
              context,
              project: project,
              isCurrent: () => current,
            ),
            'target' => showContinuationTargetPicker(
              context,
              targets: [target],
              isCurrent: () => current,
            ),
            _ => showContinuationLinkPicker(
              context,
              project: project,
              isCurrent: () => current,
            ),
          },
        );
        await _type(
          tester,
          kind == 'sheet'
              ? 'atomic'
              : kind == 'target'
              ? 'm-a'
              : 'network-b',
        );
        current = false;
        if (kind == 'new') {
          final button = find.byKey(const ValueKey('continuation-picker-new'));
          if (accept == 'keyboard') {
            Focus.of(
              tester.element(find.text('Nová samostatná síť').last),
            ).requestFocus();
            await tester.pump();
            await _key(tester, LogicalKeyboardKey.enter);
          } else {
            await tester.tap(button);
          }
          await tester.pumpAndSettle();
        } else if (accept == 'keyboard') {
          await _key(tester, LogicalKeyboardKey.enter);
        } else {
          await tester.tap(switch (kind) {
            'sheet' => _sheet('atomic'),
            'target' => _target('atomic', 'm-a'),
            _ => _link('network-b', 'nested'),
          });
          await tester.pumpAndSettle();
        }
        expect(result.done, isFalse);
        expect(_error, findsOneWidget);
        await _key(tester, LogicalKeyboardKey.escape);
        expect(result.done, isTrue);
        expect(result.value, isNull);
      });
    }
  }

  testWidgets(
    'editor cancels picker without changing the draft, glyph or project',
    (tester) async {
      final app = continuationController();
      addTearDown(app.dispose);
      final before = app.project;
      await _open<void>(
        tester,
        (context) => editContinuation(
          context,
          app,
          position: const Vec2(300, 400),
          initialGlyph: ContinuationGlyph.earth,
          initialLabel: 'PE',
        ),
      );
      await tester.tap(find.byKey(const ValueKey('continuation-link-picker')));
      await tester.pumpAndSettle();
      await _type(tester, 'RETURN');
      await _key(tester, LogicalKeyboardKey.escape);
      expect(
        tester
            .widget<TextField>(continuationField('Označení sítě'))
            .controller!
            .text,
        'PE',
      );
      expect(
        tester
            .widget<DropdownButtonFormField<ContinuationGlyph>>(
              find.byType(DropdownButtonFormField<ContinuationGlyph>),
            )
            .initialValue,
        ContinuationGlyph.earth,
      );
      expect(app.project, same(before));
      expect(app.canUndo, isFalse);
      await continuationClick(tester, 'Zrušit');
      await tester.pump(const Duration(milliseconds: 500));
    },
  );

  testWidgets(
    'editor reassignment is explicit and preserves existing network names',
    (tester) async {
      final app = continuationController();
      addTearDown(app.dispose);
      await _open<void>(
        tester,
        (context) => editContinuation(
          context,
          app,
          marker: app.sheet.continuationById('source'),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('continuation-link-picker')));
      await tester.pumpAndSettle();
      await _type(tester, 'second-network');
      await _key(tester, LogicalKeyboardKey.enter);
      expect(
        tester.widget<TextField>(continuationField('Označení sítě')).enabled,
        isFalse,
      );
      await continuationClick(tester, 'Uložit');
      expect(app.sheet.continuationById('source')!.linkId, 'second-network');
      expect(app.project.continuationLinkById('network')!.label, 'SIGNAL');
      expect(
        app.project.continuationLinkById('second-network')!.label,
        'RETURN',
      );
      expect(app.project.revision, 1);
      app.undo();
      expect(app.sheet.continuationById('source')!.linkId, 'network');
      await tester.pump(const Duration(milliseconds: 500));
    },
  );

  testWidgets(
    'editor rechecks ownership after picker returns before applying the draft',
    (tester) async {
      final app = continuationController();
      addTearDown(app.dispose);
      var checks = 0;
      final before = app.project;
      await _open<void>(
        tester,
        (context) => editContinuation(
          context,
          app,
          marker: app.sheet.continuationById('source'),
          isActive: () => ++checks == 1,
        ),
      );
      await tester.tap(find.byKey(const ValueKey('continuation-link-picker')));
      await tester.pumpAndSettle();
      await _type(tester, 'second-network');
      await _key(tester, LogicalKeyboardKey.enter);
      expect(checks, 2);
      expect(
        find.text(
          'Původní projekt, list nebo odkaz se změnil. Otevřete editor znovu.',
        ),
        findsOneWidget,
      );
      expect(
        tester
            .widget<TextField>(continuationField('Označení sítě'))
            .controller!
            .text,
        'SIGNAL',
      );
      expect(app.project, same(before));
      await continuationClick(tester, 'Zrušit');
      await tester.pump(const Duration(milliseconds: 500));
    },
  );

  testWidgets(
    'editor bounds inline peers and searches the remainder without a mutation',
    (tester) async {
      final app = continuationController(continuationProject(sameSheet: 1200));
      addTearDown(app.dispose);
      final before = app.project;
      ContinuationTarget? selected;
      await _open<void>(
        tester,
        (context) => editContinuation(
          context,
          app,
          marker: app.sheet.continuationById('source'),
          onNavigate: (target) => selected = target,
        ),
      );
      expect(find.byType(ContinuationTargetTile), findsNWidgets(4));
      final button = find.byKey(const ValueKey('continuation-editor-peers'));
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      await _type(tester, 'same-1199');
      await _key(tester, LogicalKeyboardKey.enter);
      expect(selected?.marker.id, 'same-1199');
      expect(app.project, same(before));
      expect(app.canUndo, isFalse);
      await tester.pump(const Duration(milliseconds: 500));
    },
  );
}
