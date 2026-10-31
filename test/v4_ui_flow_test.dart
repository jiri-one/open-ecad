import 'dart:convert';
import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/app/controller.dart';
import 'package:open_ecad/app/workspace.dart';
import 'package:open_ecad/app/workspace_controller.dart';
import 'package:open_ecad/editor/mounting_canvas.dart';
import 'package:open_ecad/services/project_persistence.dart';
import 'package:open_ecad/widgets/occurrence_dialog.dart';
import 'package:open_ecad/widgets/inventory.dart';
import 'package:open_ecad/widgets/report_view.dart';
import 'package:open_ecad/services/export_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

EcadProject empty(String name) => EcadProject(
  id: 'same_project',
  name: name,
  pages: [
    Sheet(id: 'same_sheet', name: 'První list', number: '01'),
    Sheet(id: 'second_sheet', name: 'Druhý list', number: '02'),
  ],
);
const article = Article(
  id: 'article',
  name: 'Demo relé',
  unit: QuantityUnit.piece,
  manufacturer: 'Synthetic Works',
  partNumber: 'DEMO-42',
  dimensionsMm: DimensionsMm(width: 40, height: 60),
);

class MemoryFiles extends ProjectFiles {
  final saved = <String, EcadProject>{};
  String path = '/tmp/synthetic-a.oecad';
  int saves = 0;
  @override
  Future<ProjectFileData?> pick() async => readPath(path);
  @override
  Future<ProjectFileData> readPath(String path) async => ProjectFileData(
    Uint8List.fromList(utf8.encode(jsonEncode(saved[path]!.toJson()))),
    name: path,
    origin: DocumentFileHandle(path: path, version: 'v1'),
  );
  @override
  Future<SavedProjectFile?> save(
    Uint8List bytes, {
    required String suggestedName,
    required bool Function() canCommit,
    DocumentFileHandle? target,
    DocumentFileHandle? currentFile,
  }) async {
    if (!canCommit()) throw const DocumentOperationSuperseded();
    saves++;
    final dest = target?.path ?? path;
    saved[dest] = EcadProject.fromJson(jsonDecode(utf8.decode(bytes)));
    return SavedProjectFile(
      name: dest,
      origin: DocumentFileHandle(path: dest, version: 'v1'),
    );
  }
}

Finder field(String label) => find.byWidgetPredicate(
  (w) => w is TextField && w.decoration?.labelText == label,
);
Future<void> saveDialog(WidgetTester tester) async {
  final save = find.descendant(
    of: find.byType(AlertDialog),
    matching: find.widgetWithText(FilledButton, 'Uložit'),
  );
  await tester.tap(save);
  await tester.pumpAndSettle();
}

class RecordingPersistence extends ProjectPersistence {
  final savedNames = <String>[];
  @override
  Future<void> saveWorkingCopy(WorkingCopy copy) async {}
  @override
  Future<SavedProjectFile?> saveAs(
    EcadProject project, {
    DocumentFileHandle? currentFile,
    required bool Function() canCommit,
  }) async {
    savedNames.add(project.name);
    return SavedProjectFile(name: '${project.name}.oecad');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(ExportFonts.load);
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'one physical piece, two functions and shared mounting remain one BOM item through save, undo and reopen',
    () async {
      final files = MemoryFiles();
      final app = EditorController(
        initialProject: empty('A'),
        persistence: ProjectPersistence(files: files),
      );
      addTearDown(app.dispose);
      expect(app.saveArticle(article), isTrue);
      expect(
        app.saveComponent(
          const Component(
            id: 'piece',
            designation: '-K1',
            articleId: 'article',
          ),
        ),
        isTrue,
      );
      expect(
        app.addOccurrence(
          app.project.componentById('piece')!,
          kind: DeviceKind.coil,
        ),
        isTrue,
      );
      final first = app.selectedDevices.single;
      app.setSheet('second_sheet');
      expect(
        app.addOccurrence(
          app.project.componentById('piece')!,
          kind: DeviceKind.contactNo,
        ),
        isTrue,
      );
      final second = app.selectedDevices.single;
      expect(first.functionId, isNot(second.functionId));
      app.addSheet(type: SheetType.cabinetLayout);
      expect(app.configureMounting(width: 300, height: 200, scale: 2), isTrue);
      expect(app.placeComponent('piece', const Vec2(55, 70)), isTrue);
      final layout = app.activeLayout!;
      app.addSheet(type: SheetType.cabinetLayout);
      expect(
        app.configureMounting(
          layout: layout,
          width: 300,
          height: 200,
          scale: 4,
          origin: const Vec2(10, 20),
        ),
        isTrue,
      );
      expect(app.bom.articles.single.requiredTotal.knownBaseUnits, 1);
      expect(app.bom.components.single.mountingSheetIds, hasLength(2));
      expect(app.placeComponent('piece', const Vec2(150, 70)), isFalse);
      expect(
        app.updatePlacement(
          layout.placements.single.copyWith(
            centerMm: const Vec2(80, 90),
            rotation: 90,
          ),
        ),
        isTrue,
      );
      expect(
        app.project.mountingLayouts.single.placements.single.centerMm,
        const Vec2(80, 90),
      );
      expect(
        app.saveComponent(
          app.project.componentById('piece')!.copyWith(designation: '-K9'),
        ),
        isTrue,
      );
      for (final d in [first, second]) {
        expect(app.componentFor(d).designation, '-K9');
      }
      expect(
        app.saveArticle(
          article.copyWith(
            name: 'Demo revize',
            dimensionsMm: const DimensionsMm(width: 45, height: 60),
          ),
        ),
        isTrue,
      );
      expect(
        app.resolver.dimensionsFor(app.project.componentById('piece')!).width,
        45,
      );
      expect(
        app.saveComponent(
          const Component(
            id: 'piece2',
            designation: '-K2',
            articleId: 'article',
          ),
        ),
        isTrue,
      );
      expect(app.bom.articles.single.requiredTotal.knownBaseUnits, 2);
      app.setSheet('same_sheet');
      app.select({first.id});
      app.deleteSelection();
      expect(app.project.components, hasLength(2));
      expect(app.bom.articles.single.requiredTotal.knownBaseUnits, 2);
      app.undo();
      expect(app.sheet.devices.single.id, first.id);
      expect(await app.saveProject(), isTrue);
      expect(app.dirty, isFalse);
      final other = EditorController(
        startEmpty: true,
        persistence: ProjectPersistence(files: files),
      );
      addTearDown(other.dispose);
      expect(await other.openProject(path: files.path), isTrue);
      expect(other.project.toJson(), app.project.toJson());
      expect(other.bom.articles.single.requiredTotal.knownBaseUnits, 2);
    },
  );

  test(
    'workspace distinguishes identical IDs and keeps edits undo save and tabs independent',
    () async {
      final files = MemoryFiles();
      final a = EditorController(
        initialProject: empty('A'),
        persistence: ProjectPersistence(files: files),
      );
      final b = EditorController(
        initialProject: empty('B'),
        persistence: ProjectPersistence(files: files),
      );
      final workspace = WorkspaceController(a)..add(b);
      addTearDown(() {
        workspace.dispose();
        a.dispose();
      });
      workspace.openSheet(a, 'same_sheet');
      workspace.openSheet(a, 'second_sheet');
      workspace.openSheet(b, 'second_sheet');
      expect(workspace.tabs, hasLength(4));
      a.renameProject('A edited');
      b.renameProject('B edited');
      a.undo();
      expect(a.project.name, 'A');
      expect(b.project.name, 'B edited');
      expect(await a.saveProject(), isTrue);
      expect(files.saved[files.path]!.name, 'A');
      expect(b.dirty, isTrue);
      workspace.closeTab(SheetTab(a.documentSessionId, 'same_sheet'));
      expect(workspace.documents, hasLength(2));
      expect(workspace.tabs, hasLength(3));
      expect(await workspace.open(path: files.path), isTrue);
      expect(workspace.documents, hasLength(2));
      expect(workspace.active, same(a));
      workspace.closeTab(SheetTab(a.documentSessionId, 'second_sheet'));
      expect(workspace.documents, hasLength(2));
      workspace.closeDocument(a);
      expect(workspace.documents, [b]);
      expect(
        workspace.tabs.every((t) => t.sessionId == b.documentSessionId),
        isTrue,
      );
      expect(b.project.name, 'B edited');
    },
  );

  test(
    'workspace restores each recovery session without replacing open documents',
    () async {
      final persistence = ProjectPersistence(files: MemoryFiles());
      final a = EditorController(
        initialProject: empty('A'),
        persistence: persistence,
      );
      final b = EditorController(
        initialProject: empty('B'),
        persistence: persistence,
      );
      final aId = a.documentSessionId, bId = b.documentSessionId;
      a.renameProject('A upravený');
      b.renameProject('B upravený');
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(await persistence.listRecoveryIds(), containsAll([aId, bId]));
      a.dispose();
      b.dispose();
      final initial = EditorController(
        startEmpty: true,
        persistence: persistence,
      );
      final workspace = WorkspaceController(initial);
      addTearDown(() {
        workspace.dispose();
        initial.dispose();
      });
      expect(await workspace.restore(aId), isTrue);
      final restoredA = workspace.active;
      expect(restoredA.project.name, 'A upravený');
      expect(restoredA.dirty, isTrue);
      expect(await workspace.restore(bId), isTrue);
      expect(workspace.active.project.name, 'B upravený');
      expect(workspace.documents, hasLength(3));
      expect(await workspace.restore(aId), isTrue);
      expect(workspace.active, same(restoredA));
      expect(workspace.documents, hasLength(3));
      expect(workspace.document(bId)!.project.name, 'B upravený');
    },
  );
  testWidgets(
    'article and component forms create real data; edits update live report and assembly',
    (tester) async {
      tester.view.physicalSize = const Size(1600, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final app = EditorController(initialProject: empty('UI'));
      addTearDown(app.dispose);
      await tester.pumpWidget(OpenEcadApp(controller: app));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(Tab, 'Artikly'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Nový artikl'));
      await tester.pumpAndSettle();
      for (final e
          in {
            'Název artiklu': 'Demo relé',
            'Výrobce': 'Synthetic Works',
            'Objednací kód': 'DEMO-42',
            'Šířka mm': '40,5',
            'Výška mm': '60',
          }.entries) {
        await tester.ensureVisible(field(e.key));
        await tester.enterText(field(e.key), e.value);
      }
      await saveDialog(tester);
      expect(app.project.articles.single.dimensionsMm!.width, 40.5);
      await tester.tap(find.widgetWithText(Tab, 'Přístroje'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Nový kus / materiál'));
      await tester.pumpAndSettle();
      await tester.enterText(field('Označení'), '-K1');
      final dropdown = find.byWidgetPredicate(
        (w) =>
            w is DropdownButtonFormField<String> &&
            w.decoration.labelText == 'Artikl',
      );
      await tester.ensureVisible(dropdown);
      await tester.tap(dropdown);
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Demo relé · DEMO-42').last);
      await tester.pumpAndSettle();
      await saveDialog(tester);
      final piece = app.project.components.single;
      expect(piece.articleId, app.project.articles.single.id);
      final pieceMenu = find.descendant(
        of: find.byType(InventoryPanel),
        matching: find.byType(PopupMenuButton<String>),
      );
      await tester.tap(pieceMenu);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Další elektrické zobrazení…'));
      await tester.pumpAndSettle();
      final symbol = find.byWidgetPredicate(
        (w) =>
            w is DropdownButtonFormField<String> &&
            w.decoration.labelText == 'Zobrazení',
      );
      await tester.tap(symbol);
      await tester.pumpAndSettle();
      await tester.tap(
        find.text(SymbolCatalog.definitionFor(DeviceKind.coil).label).last,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Použít'));
      await tester.pumpAndSettle();
      expect(app.sheet.devices.single.kind, DeviceKind.coil);
      final firstFunction = app.sheet.devices.single.functionId;
      app.setSheet('second_sheet');
      app.addOccurrence(
        app.project.componentById(piece.id)!,
        kind: DeviceKind.contactNo,
      );
      await tester.pumpAndSettle();
      await tester.tap(pieceMenu);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Další elektrické zobrazení…'));
      await tester.pumpAndSettle();
      final function = find.byWidgetPredicate(
        (w) =>
            w is DropdownButtonFormField<String> &&
            w.decoration.labelText == 'Elektrická funkce',
      );
      await tester.tap(function);
      await tester.pumpAndSettle();
      final label =
          app.project
              .componentById(piece.id)!
              .electrical!
              .functionById(firstFunction)!
              .name;
      await tester.tap(find.text('$label (2 vývodů)').last);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Použít'));
      await tester.pumpAndSettle();
      expect(app.sheet.devices.last.mode, OccurrenceMode.reference);
      expect(app.sheet.devices.last.functionId, firstFunction);
      app.addSheet(type: SheetType.cabinetLayout);
      app.configureMounting(width: 300, height: 200, scale: 2);
      app.placeComponent(piece.id, const Vec2(60, 60));
      await tester.pumpAndSettle();
      expect(find.byType(MountingCanvas), findsOneWidget);
      app.viewport.zoomIn();
      await tester.pump();
      expect(app.viewport.zoom, closeTo(1.2, .001));
      app.viewport.fit();
      await tester.pump();
      expect(app.viewport.zoom, 1);
      expect(tester.takeException(), isNull);
      app.addSheet(type: SheetType.billOfMaterials);
      await tester.pumpAndSettle();
      expect(find.byType(ReportView), findsOneWidget);
      app.viewport.zoomIn();
      await tester.pump();
      expect(app.viewport.zoom, closeTo(1.2, .001));
      app.viewport.fit();
      await tester.pump();
      expect(app.viewport.zoom, 1);
      expect(app.bom.articles.single.requiredTotal.knownBaseUnits, 1);
      await tester.tap(find.widgetWithText(Tab, 'Artikly'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Demo relé').first);
      await tester.pumpAndSettle();
      await tester.enterText(field('Název artiklu'), 'Změněný artikl');
      await saveDialog(tester);
      expect(app.bom.articles.single.article!.name, 'Změněný artikl');
      expect(app.bom.articles.single.requiredTotal.knownBaseUnits, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 500));
    },
  );

  testWidgets(
    'port rename and side edit preserve wired identity; connected port deletion is rejected atomically',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final app = EditorController(initialProject: empty('Ports'));
      addTearDown(app.dispose);
      app.saveComponent(const Component(id: 'block', designation: '-A1'));
      app.addOccurrence(app.project.componentById('block')!);
      final device = app.selectedDevices.single;
      final component = app.componentFor(device),
          function = app.componentFor(device).electrical!.functions.single;
      app.execute([
        UpdateComponent(
          component.copyWith(
            electrical: ElectricalModel(
              terminals: const [ComponentTerminal(id: 't', designation: 'OLD')],
              functions: [
                function.copyWith(terminalIds: ['t']),
              ],
            ),
          ),
        ),
        UpdateDevice(
          app.sheet.id,
          device.copyWith(
            symbol: PortBlockSpec(
              width: 160,
              height: 120,
              ports: const [
                BlockPort(
                  id: 'port',
                  terminalId: 't',
                  side: PortSide.left,
                  fraction: .5,
                ),
              ],
            ),
          ),
        ),
      ], 'Seed port');
      app.addContinuation(position: const Vec2(80, 250), label: 'DEMO');
      app.connect(
        TerminalRef(deviceId: device.id, portId: 'port'),
        ContinuationRef(markerId: app.sheet.continuations.single.id),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder:
                  (context) => TextButton(
                    onPressed:
                        () => editPorts(
                          context,
                          app,
                          app.sheet.deviceById(device.id)!,
                        ),
                    child: const Text('Edit'),
                  ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      await tester.enterText(field('Vývod'), 'IN1');
      final side = find.byType(DropdownButtonFormField<PortSide>);
      await tester.tap(side);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Vpravo').last);
      await tester.pumpAndSettle();
      await saveDialog(tester);
      expect(
        app.resolver.port(app.sheet.deviceById(device.id)!, 'port')!.label,
        'IN1',
      );
      expect(
        app.sheet.wires.single.from,
        TerminalRef(deviceId: device.id, portId: 'port'),
      );
      expect(terminalIdFor(app.sheet.deviceById(device.id)!, 'port'), 't');
      final revision = app.project.revision;
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Odstranit port'));
      await tester.pumpAndSettle();
      await saveDialog(tester);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(app.project.revision, revision);
      expect(app.sheet.wires, hasLength(1));
      await tester.tap(find.text('Zrušit'));
      await tester.pumpAndSettle();
      app.undo();
      expect(
        app.resolver.port(app.sheet.deviceById(device.id)!, 'port')!.label,
        'OLD',
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 500));
    },
  );
  testWidgets(
    'tabs switch properties and Save As to the active session; closing only a tab leaves documents intact',
    (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final persistence = RecordingPersistence();
      EditorController doc(String name) {
        final app = EditorController(
          initialProject: empty(name),
          persistence: persistence,
        );
        final seed = createBuiltinComponent(
          componentId: 'piece',
          deviceId: 'occurrence',
          kind: DeviceKind.coil,
          designation: '-K1',
          position: const Vec2(250, 250),
          description: name,
        );
        app.execute([
          AddComponent(seed.component),
          AddDevice(app.sheet.id, seed.device),
        ], 'Seed');
        app.select({'occurrence'});
        app.setPanel(SidePanel.properties);
        return app;
      }

      final a = doc('A'), b = doc('B');
      addTearDown(a.dispose);
      await tester.pumpWidget(OpenEcadApp(controller: a));
      await tester.pumpAndSettle();
      final workspace =
          tester
              .widget<EditorWorkspace>(find.byType(EditorWorkspace))
              .workspace!;
      workspace.add(b);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field('Popis')).controller!.text, 'B');
      await tester.tap(find.textContaining('A ● · 01 První list'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field('Popis')).controller!.text, 'A');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(persistence.savedNames, ['A']);
      expect(a.dirty, isFalse);
      expect(b.dirty, isTrue);
      workspace.openSheet(b, 'second_sheet');
      workspace.openSheet(a, 'second_sheet');
      await tester.pumpAndSettle();
      expect(workspace.tabs, hasLength(4));
      workspace.closeTab(workspace.activeTab!);
      await tester.pumpAndSettle();
      expect(workspace.tabs, hasLength(3));
      expect(workspace.documents, hasLength(2));
      workspace.openSheet(b, 'same_sheet');
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Soubor'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Zavřít aktivní projekt…'));
      await tester.pumpAndSettle();
      expect(find.text('Neuložené změny · B'), findsOneWidget);
      await tester.tap(find.text('Zrušit'));
      await tester.pumpAndSettle();
      expect(workspace.documents, hasLength(2));
      await tester.tap(find.byTooltip('Soubor'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Zavřít aktivní projekt…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Zahodit změny'));
      await tester.pumpAndSettle();
      expect(workspace.documents, [a]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 500));
    },
  );

  testWidgets(
    'mounting drag commits millimetres once and preserves shared layout after rotation and undo',
    (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final app = EditorController(initialProject: empty('Mount'));
      addTearDown(app.dispose);
      app.saveArticle(article);
      app.saveComponent(
        const Component(id: 'piece', designation: '-K1', articleId: 'article'),
      );
      app.addSheet(type: SheetType.cabinetLayout);
      app.configureMounting(width: 300, height: 200, scale: 2);
      app.placeComponent('piece', const Vec2(80, 80));
      await tester.pumpWidget(OpenEcadApp(controller: app));
      await tester.pumpAndSettle();
      final canvas = find.byKey(const ValueKey('mounting-surface'));
      final box = tester.getRect(canvas);
      final scale = box.width / app.sheet.width;
      final transform = MountingTransform(app.sheet, app.sheet.mountingView!);
      final pos = transform.toSheet(const Vec2(80, 80));
      final before = app.project.revision;
      await tester.dragFrom(
        box.topLeft + Offset(pos.x * scale, pos.y * scale),
        Offset(
          20 * transform.unitsPerMm * scale,
          30 * transform.unitsPerMm * scale,
        ),
      );
      await tester.pumpAndSettle();
      expect(app.project.revision, before + 1);
      expect(
        app.activeLayout!.placements.single.centerMm,
        const Vec2(100, 110),
      );
      app.rotateSelection();
      expect(app.activeLayout!.placements.single.rotation, 90);
      app.undo();
      app.undo();
      expect(app.activeLayout!.placements.single.centerMm, const Vec2(80, 80));
      expect(app.bom.articles.single.requiredTotal.knownBaseUnits, 1);
      await tester.pumpAndSettle();
      app.viewport.zoomIn();
      await tester.pumpAndSettle();
      final viewer = tester.widget<InteractiveViewer>(
        find.descendant(
          of: find.byType(MountingCanvas),
          matching: find.byType(InteractiveViewer),
        ),
      );
      final matrix = viewer.transformationController!;
      final translation = matrix.value.getTranslation();
      final panRevision = app.project.revision;
      final transformed = tester.getRect(canvas);
      await tester.dragFrom(
        transformed.topLeft +
            Offset(transformed.width * .7, transformed.height * .6),
        const Offset(-45, -30),
      );
      await tester.pumpAndSettle();
      expect(matrix.value.getTranslation().x, lessThan(translation.x));
      expect(app.project.revision, panRevision);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 500));
    },
  );
  testWidgets(
    'material form accepts decimal comma and preserves unknown reserve quantity',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final app = EditorController(initialProject: empty('Material'));
      addTearDown(app.dispose);
      app.saveArticle(
        const Article(
          id: 'metre',
          name: 'Demo materiál',
          unit: QuantityUnit.metre,
        ),
      );
      app.saveComponent(
        const Component(
          id: 'material',
          kind: ComponentKind.material,
          articleId: 'metre',
          quantity: Quantity.millimetres(null),
          usage: ComponentUsage.spare,
          procurement: Procurement(source: ProcurementSource.available),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder:
                  (context) => TextButton(
                    onPressed:
                        () => editComponent(
                          context,
                          app,
                          component: app.project.componentById('material'),
                        ),
                    child: const Text('Edit'),
                  ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(field('Množství'));
      await tester.enterText(field('Množství'), '2,75');
      await saveDialog(tester);
      expect(app.project.componentById('material')!.quantity.baseUnits, 2750);
      expect(app.bom.articles.single.available.knownBaseUnits, 2750);
      expect(app.bom.articles.single.toPurchase.knownBaseUnits, 0);
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(field('Množství'));
      await tester.enterText(field('Množství'), '');
      await saveDialog(tester);
      expect(app.project.componentById('material')!.quantity.baseUnits, isNull);
      expect(app.bom.articles.single.spare.isKnown, isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 500));
    },
  );
}
