import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:open_ecad/app/controller.dart';
import 'package:open_ecad/app/workspace.dart';
import 'package:open_ecad/editor/schematic_canvas.dart';
import 'package:open_ecad/editor/mounting_canvas.dart';
import 'package:open_ecad/services/project_persistence.dart';
import 'package:shared_preferences/shared_preferences.dart';

EcadProject editingProject() {
  final seed = createBuiltinComponent(
    componentId: 'piece',
    deviceId: 'symbol',
    kind: DeviceKind.coil,
    designation: '-K1',
    position: const Vec2(550, 390),
  );
  return EcadProject(
    id: 'project',
    name: 'Synthetic editor',
    components: [seed.component],
    articles: const [
      Article(
        id: 'article',
        name: 'Synthetic relay',
        partNumber: 'R-42',
        unit: QuantityUnit.piece,
      ),
    ],
    continuationLinks: const [ContinuationLink(id: 'link', label: 'SIGNAL')],
    pages: [
      Sheet(
        id: 'sheet',
        name: 'Control',
        number: '01',
        devices: [seed.device],
        continuations: const [
          ContinuationMarker(
            id: 'marker',
            linkId: 'link',
            position: Vec2(400, 250),
          ),
        ],
        wires: [
          Wire(
            id: 'wire',
            from: TerminalRef(
              deviceId: seed.device.id,
              portId: geometryFor(seed.device).ports.first.id,
            ),
            to: const ContinuationRef(markerId: 'marker'),
          ),
        ],
      ),
      Sheet(
        id: 'other',
        name: 'Reference',
        number: '02',
        devices: [
          seed.device.copyWith(id: 'reference', mode: OccurrenceMode.reference),
        ],
      ),
    ],
  );
}

class MemoryPersistence extends ProjectPersistence {
  @override
  Future<void> saveWorkingCopy(WorkingCopy copy) async {}
}

Finder field(String label) => find.byWidgetPredicate(
  (w) => w is TextField && w.decoration?.labelText == label,
);

Future<void> click(WidgetTester tester, String text) async {
  await tester.ensureVisible(find.text(text).last);
  await tester.tap(find.text(text).last);
  await tester.pumpAndSettle();
}

Future<void> mountEditor(WidgetTester tester, EditorController app) async {
  tester.view.physicalSize = const Size(1600, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(OpenEcadApp(controller: app));
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('Zobrazit asistenta'));
  await tester.pumpAndSettle();
  app.viewport.reset();
  await tester.pump();
}

Future<void> doubleClickSymbol(WidgetTester tester) async {
  final position = tester.getCenter(find.byType(SchematicCanvas));
  await tester.tapAt(position);
  await tester.pump(const Duration(milliseconds: 70));
  await tester.tapAt(position);
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets('double click edits the symbol with the inspector hidden', (
    tester,
  ) async {
    final app = EditorController(
      initialProject: editingProject(),
      persistence: MemoryPersistence(),
    );
    addTearDown(app.dispose);
    await mountEditor(tester, app);
    await doubleClickSymbol(tester);
    expect(app.selectedIds, {'symbol'});
    expect(find.byType(AlertDialog), findsOneWidget);
    final designation = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.labelText == 'Označení',
    );
    await tester.enterText(designation, '-K9');
    await tester.tap(find.text('Použít vlastnosti'));
    await tester.pumpAndSettle();
    expect(app.project.componentById('piece')!.designation, '-K9');
    await tester.enterText(field('Popis'), 'Relay description');
    await click(tester, 'Použít vlastnosti');
    await click(tester, 'Komponenta, artikl a dostupnost…');
    final article = find.byWidgetPredicate(
      (w) =>
          w is DropdownButtonFormField<String> &&
          w.decoration.labelText == 'Artikl',
    );
    await tester.ensureVisible(article);
    await tester.tap(article);
    await tester.pumpAndSettle();
    await click(tester, 'Synthetic relay · R-42');
    await click(tester, 'Uložit');
    expect(app.project.components, hasLength(1));
    expect(app.project.pages.expand((s) => s.devices), hasLength(2));
    expect(app.bom.articles.single.requiredTotal.knownBaseUnits, 1);
    expect(
      app.componentFor(app.project.pages.last.devices.single).designation,
      '-K9',
    );
    expect(
      app.componentFor(app.project.pages.last.devices.single).description,
      'Relay description',
    );
    final reopened = EcadProject.fromJson(app.project.toJson());
    expect(reopened.componentById('piece')!.articleId, 'article');
    expect(reopened.pages.last.devices.single.componentId, 'piece');
    app.undo();
    expect(app.project.componentById('piece')!.articleId, isNull);
    app.redo();
    expect(app.project.componentById('piece')!.articleId, 'article');
    expect(app.project.pages.first.wires.single.id, 'wire');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets(
    'function and port edits from the symbol keep wires and their IDs on the original sheet',
    (tester) async {
      final app = EditorController(
        initialProject: editingProject(),
        persistence: MemoryPersistence(),
      );
      addTearDown(app.dispose);
      final original = app.sheet.devices.single;
      final wire = app.sheet.wires.single;
      final terminal = terminalIdFor(
        original,
        (wire.from as TerminalRef).portId,
      );
      await mountEditor(tester, app);
      await doubleClickSymbol(tester);
      await click(tester, 'Funkce, blok a vývody…');
      await tester.enterText(field('Název funkce'), 'Edited winding');
      await tester.enterText(field('Vývod').first, 'IN');
      app.setSheet('other');
      await tester.pumpAndSettle();
      await click(tester, 'Uložit');
      final updated = app.project.pages.first.devices.single;
      expect(updated.id, original.id);
      expect(
        terminalIdFor(updated, (wire.from as TerminalRef).portId),
        terminal,
      );
      expect(app.project.pages.first.wires.single.from, wire.from);
      expect(
        app.resolver.port(updated, (wire.from as TerminalRef).portId)!.label,
        'IN',
      );
      expect(
        app.project
            .componentById('piece')!
            .electrical!
            .functionById(updated.functionId)!
            .name,
        'Edited winding',
      );
      expect(app.sheet.devices.single.mode, OccurrenceMode.reference);
      app.undo();
      expect(
        app.resolver
            .port(
              app.project.pages.first.devices.single,
              (wire.from as TerminalRef).portId,
            )!
            .label,
        isNot('IN'),
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 500));
    },
  );

  testWidgets(
    'single selection opens properties and F4 edits with the panel closed',
    (tester) async {
      final app = EditorController(
        initialProject: editingProject(),
        persistence: MemoryPersistence(),
      );
      addTearDown(app.dispose);
      await mountEditor(tester, app);
      await tester.tapAt(tester.getCenter(find.byType(SchematicCanvas)));
      await tester.pump();
      expect(app.sidePanel, SidePanel.properties);
      expect(field('Označení'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.f4);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await click(tester, 'Zavřít');
      await tester.tap(find.byTooltip('Zobrazit vlastnosti'));
      await tester.pumpAndSettle();
      expect(field('Označení'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 500));
    },
  );

  testWidgets(
    'open component dialog stays with the originating project on a tab switch',
    (tester) async {
      final a = EditorController(
        initialProject: editingProject(),
        persistence: MemoryPersistence(),
      );
      final b = EditorController(
        initialProject: editingProject(),
        persistence: MemoryPersistence(),
      );
      addTearDown(a.dispose);
      await mountEditor(tester, a);
      await doubleClickSymbol(tester);
      await click(tester, 'Komponenta, artikl a dostupnost…');
      await tester.enterText(field('Označení').last, '-K7');
      final workspace =
          tester
              .widget<EditorWorkspace>(find.byType(EditorWorkspace))
              .workspace!;
      workspace.add(b);
      await tester.pumpAndSettle();
      await click(tester, 'Uložit');
      expect(a.project.componentById('piece')!.designation, '-K7');
      expect(b.project.componentById('piece')!.designation, '-K1');
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 500));
    },
  );

  testWidgets(
    'a dialog cannot recreate a component after replacement of its document',
    (tester) async {
      final app = EditorController(
        initialProject: editingProject(),
        persistence: MemoryPersistence(),
      );
      addTearDown(app.dispose);
      await mountEditor(tester, app);
      await doubleClickSymbol(tester);
      await click(tester, 'Komponenta, artikl a dostupnost…');
      await tester.enterText(field('Označení').last, '-K7');
      app.newProject();
      await tester.pumpAndSettle();
      final save = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, 'Uložit'),
      );
      if (save.evaluate().isNotEmpty) {
        await tester.tap(save);
        await tester.pumpAndSettle();
      }
      expect(app.project.components, isEmpty);
      expect(
        find.textContaining('Původní projekt již není otevřen.'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 500));
    },
  );

  testWidgets(
    'nested editor captures its document before the first dialog frame',
    (tester) async {
      final app = EditorController(
        initialProject: editingProject(),
        persistence: MemoryPersistence(),
      );
      addTearDown(app.dispose);
      await mountEditor(tester, app);
      await doubleClickSymbol(tester);
      final action = find.text('Komponenta, artikl a dostupnost…');
      await tester.ensureVisible(action);
      await tester.tap(action);
      app.newProject();
      await tester.pumpAndSettle();
      expect(find.text('Původní projekt již není otevřen.'), findsOneWidget);
      expect(field('Označení'), findsNothing);
      expect(app.project.components, isEmpty);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 500));
    },
  );

  testWidgets('mounting symbol opens the same physical piece by double click', (
    tester,
  ) async {
    final app = EditorController(
      initialProject: editingProject(),
      persistence: MemoryPersistence(),
    );
    addTearDown(app.dispose);
    app.saveComponent(
      app.project
          .componentById('piece')!
          .copyWith(
            mountingSizeOverrideMm: const DimensionsMm(width: 40, height: 60),
          ),
    );
    app.addSheet(type: SheetType.cabinetLayout);
    app.configureMounting(width: 300, height: 200, scale: 2);
    app.placeComponent('piece', const Vec2(80, 80));
    await mountEditor(tester, app);
    final rect = tester.getRect(find.byKey(const ValueKey('mounting-surface')));
    final transform = MountingTransform(app.sheet, app.sheet.mountingView!);
    final p = transform.toSheet(const Vec2(80, 80));
    final scale = rect.width / app.sheet.width;
    final point = rect.topLeft + Offset(p.x * scale, p.y * scale);
    await tester.tapAt(point);
    await tester.pump(const Duration(milliseconds: 70));
    await tester.tapAt(point);
    await tester.pumpAndSettle();
    expect(find.byType(MountingCanvas), findsOneWidget);
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.enterText(field('Označení'), '-K8');
    await click(tester, 'Uložit');
    expect(app.project.components.single.designation, '-K8');
    expect(app.activeLayout!.placements.single.componentId, 'piece');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 500));
  });
}
