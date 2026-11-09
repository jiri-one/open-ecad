import 'dart:convert';
import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/app/controller.dart';
import 'package:open_ecad/app/workspace.dart';
import 'package:open_ecad/editor/schematic_canvas.dart';
import 'package:open_ecad/services/export_fonts.dart';
import 'package:open_ecad/services/project_export.dart';
import 'package:open_ecad/services/wire_hover_info.dart';
import 'package:open_ecad/widgets/structure_tree.dart';
import 'package:open_ecad/widgets/terminal_symbol_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'device_editing_feedback_test.dart' as ui;

EcadProject structuredScene() {
  final project = ui.editingProject();
  final a = StructureContext(functionPath: ['FUNC'], locationPath: ['ROOM/1']);
  final b = StructureContext(functionPath: ['FUNC'], locationPath: ['ROOM/2']);
  final other = createBuiltinComponent(
    componentId: 'second-piece',
    deviceId: 'second-symbol',
    kind: DeviceKind.coil,
    designation: '-K1',
    position: const Vec2(250, 250),
  );
  return project.copyWith(
    components: [
      project.components.first.copyWith(
        designation: null,
        reference: ComponentReference(context: a, localDesignation: 'K1'),
      ),
      other.component.copyWith(
        designation: null,
        reference: ComponentReference(context: b, localDesignation: 'K1'),
      ),
    ],
    pages: [
      project.pages.first.copyWith(structure: a),
      project.pages.last.copyWith(
        number: '01',
        structure: b,
        devices: [...project.pages.last.devices, other.device],
      ),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(ExportFonts.load);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'symbol editor changes explicit structure, updates crossrefs and supports duplicate local names',
    (tester) async {
      final app = EditorController(
        initialProject: structuredScene(),
        persistence: ui.MemoryPersistence(),
      );
      addTearDown(app.dispose);
      await ui.mountEditor(tester, app);
      await ui.doubleClickSymbol(tester);
      await ui.click(tester, 'Komponenta, artikl a dostupnost…');
      await tester.enterText(ui.field('Označení umístění (+)'), 'ROOM/3');
      await tester.enterText(
        ui.field('Označení produktu (-)'),
        'GROUP\nUNIT.1',
      );
      await tester.pump();
      expect(find.text('=FUNC+ROOM/3-GROUP-UNIT.1-K1'), findsOneWidget);
      await ui.click(tester, 'Uložit');
      expect(
        app.project.componentById('piece')!.reference!.context.productPath,
        ['GROUP', 'UNIT.1'],
      );
      expect(app.project.pages.last.devices.first.componentId, 'piece');
      final svg = ProjectExportService().svg(app.project);
      expect(svg, contains('=FUNC+ROOM/3-GROUP-UNIT.1-K1'));
      expect(svg, contains('=FUNC+ROOM/2/01'));
      final hover =
          resolveWireHoverInfo(
            resolver: app.resolver,
            sheetId: 'sheet',
            wireId: 'wire',
          )!;
      expect(hover.label, contains('=FUNC+ROOM/3-GROUP-UNIT.1-K1:'));
      app.undo();
      expect(
        app.resolver.fullDesignation(app.project.components.first),
        '=FUNC+ROOM/1-K1',
      );
      final copy = EcadProject.fromJson(
        jsonDecode(jsonEncode(app.project.toJson())),
      );
      expect(copy.pages.map(fullPageDesignation), [
        '=FUNC+ROOM/1/01',
        '=FUNC+ROOM/2/01',
      ]);
      await ui.click(tester, 'Zavřít');
      expect(find.byType(StructureTree<Sheet>), findsOneWidget);
      final search = find.byWidgetPredicate(
        (w) =>
            w is TextField && w.decoration?.hintText == 'Najít list nebo typ…',
      );
      await tester.enterText(search, 'ROOM/2');
      await tester.pumpAndSettle();
      expect(find.text('=FUNC+ROOM/2/01 · Reference'), findsOneWidget);
      expect(find.text('=FUNC+ROOM/1/01 · Control'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 500));
    },
  );

  test(
    'new pieces inherit once; occurrences, branch rename, copies and undo preserve IDs',
    () {
      final app = EditorController(
        initialProject: structuredScene(),
        persistence: ui.MemoryPersistence(),
      );
      addTearDown(app.dispose);
      final original = app.project.components.first;
      app.setSheet('other');
      app.placeDevice(DeviceKind.coil, const Vec2(800, 300));
      expect(
        app
            .componentFor(app.selectedDevices.single)
            .reference!
            .localDesignation,
        'K2',
      );
      expect(
        app.componentFor(app.selectedDevices.single).reference!.context,
        app.sheet.structure,
      );
      final copy = app.duplicateInventoryComponent(original)!;
      expect(copy.reference!.context, app.sheet.structure);
      expect(copy.reference!.localDesignation, 'K3');
      expect(
        copy.electrical!.terminals
            .map((t) => t.id)
            .toSet()
            .intersection(
              original.electrical!.terminals.map((t) => t.id).toSet(),
            ),
        isEmpty,
      );
      expect(
        app.addOccurrence(
          original,
          functionId: original.electrical!.functions.first.id,
          kind: DeviceKind.coil,
          mode: OccurrenceMode.reference,
          position: const Vec2(500, 500),
        ),
        isTrue,
      );
      expect(
        app.project.componentById(original.id)!.reference!.context,
        original.reference!.context,
      );
      app.updateSheet(
        app.sheet.copyWith(structure: StructureContext(locationPath: ['NEW'])),
      );
      expect(
        app.project.componentById(copy.id)!.reference!.context,
        copy.reference!.context,
      );
      app.undo();
      expect(
        app.renameStructureBranch(
          StructureAspect.location,
          ['ROOM/2'],
          ['ROOM/1'],
        ),
        isFalse,
      );
      expect(
        app.renameStructureBranch(
          StructureAspect.location,
          ['ROOM/2'],
          ['LAB/2'],
        ),
        isTrue,
      );
      expect(
        app.project.componentById(copy.id)!.reference!.context.locationPath,
        ['LAB/2'],
      );
      expect(
        app.project.componentById(original.id)!.reference!.context.locationPath,
        ['ROOM/1'],
      );
      app.undo();
      expect(
        app.project.componentById(copy.id)!.reference!.context.locationPath,
        ['ROOM/2'],
      );
      app.placeTerminal(const Vec2(800, 450));
      final firstTerminal = app.componentFor(app.selectedDevices.single);
      app.setSheet('sheet');
      app.placeTerminal(const Vec2(800, 450));
      final secondTerminal = app.componentFor(app.selectedDevices.single);
      expect(
        firstTerminal.terminal!.stripId,
        isNot(secondTerminal.terminal!.stripId),
      );
      expect(app.resolver.contextFor(secondTerminal), app.sheet.structure);
    },
  );

  testWidgets(
    'sheet settings and both structure trees edit exact paths without relocating existing pieces',
    (tester) async {
      final app = EditorController(
        initialProject: structuredScene(),
        persistence: ui.MemoryPersistence(),
      );
      addTearDown(app.dispose);
      final original = app.project.components.first.reference!.full;
      await ui.mountEditor(tester, app);
      await tester.tap(find.byTooltip('Vlastnosti listu'));
      await tester.pumpAndSettle();
      await ui.click(tester, 'Číslo, papír a vlastnosti…');
      await tester.enterText(ui.field('Označení umístění (+)'), 'ROOM/3');
      await tester.enterText(ui.field('Kód dokumentu (&)'), 'DOC');
      await ui.click(tester, 'Uložit');
      expect(fullPageDesignation(app.sheet), '=FUNC+ROOM/3&DOC/01');
      expect(
        app.resolver.fullDesignation(app.project.components.first),
        original,
      );
      expect(find.text('=FUNC+ROOM/3&DOC/01 · Control'), findsOneWidget);
      await tester.tap(find.text('Přístroje'));
      await tester.pumpAndSettle();
      expect(find.byType(StructureTree<ComponentRow>), findsOneWidget);
      final search = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.hintText == 'Hledat…',
      );
      await tester.enterText(search, 'K1');
      await tester.pumpAndSettle();
      expect(find.text('=FUNC+ROOM/1-K1'), findsOneWidget);
      expect(find.text('=FUNC+ROOM/2-K1'), findsOneWidget);
      final branch =
          find
              .ancestor(
                of: find.text('+ROOM/2'),
                matching: find.byType(ExpansionTile),
              )
              .first;
      final rename =
          find
              .descendant(
                of: branch,
                matching: find.byTooltip('Přejmenovat větev'),
              )
              .first;
      await tester.ensureVisible(rename);
      await tester.tap(rename);
      await tester.pumpAndSettle();
      await tester.enterText(ui.field('Nový kód úrovně'), 'CELL/2');
      await ui.click(tester, 'Uložit');
      expect(app.project.pages.last.structure.locationPath, ['CELL/2']);
      expect(
        app.project
            .componentById('second-piece')!
            .reference!
            .context
            .locationPath,
        ['CELL/2'],
      );
      expect(app.project.components.first.reference!.full, original);
      app.undo();
      expect(app.project.pages.last.structure.locationPath, ['ROOM/2']);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 500));
    },
  );

  testWidgets(
    'toolbar inserts a circular terminal and the symbol edits directions without creating pieces',
    (tester) async {
      final app = EditorController(
        initialProject: EcadProject(
          id: 'p',
          name: 'Terminal UI',
          pages: [
            Sheet(
              id: 's',
              name: 'Terminals',
              number: '01',
              structure: StructureContext(locationPath: ['CELL']),
            ),
          ],
        ),
        persistence: ui.MemoryPersistence(),
      );
      addTearDown(app.dispose);
      await ui.mountEditor(tester, app);
      await tester.tap(find.byTooltip('Svorka · 1–4 směry'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('terminal-symbol-side-right')),
      );
      await ui.click(tester, 'Uložit');
      await tester.tapAt(tester.getCenter(find.byType(SchematicCanvas)));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      final device = app.sheet.devices.single;
      expect((device.symbol as TerminalSymbolSpec).sides, hasLength(3));
      expect(app.project.terminalStrips, hasLength(1));
      expect(app.project.components, hasLength(1));
      await ui.doubleClickSymbol(tester);
      await ui.click(tester, 'Směry svorky (1–4)…');
      await tester.tap(find.byKey(const ValueKey('terminal-symbol-side-left')));
      await ui.click(tester, 'Uložit');
      final edited = app.sheet.devices.single;
      expect((edited.symbol as TerminalSymbolSpec).sides, hasLength(4));
      expect(app.bom.articles.single.requiredTotal.knownBaseUnits, 1);
      expect(
        app.resolver.ports(edited).map((p) => p.node).toSet(),
        hasLength(1),
      );
      await ui.click(tester, 'Funkce, blok a vývody…');
      await tester.enterText(ui.field('Název funkce'), 'Through');
      await tester.enterText(ui.field('Signál uzlu'), '24V');
      await tester.enterText(ui.field('Vývod').first, 'A');
      await ui.click(tester, 'Uložit');
      expect(
        app.project.components.single.electrical!.functions.single.name,
        'Through',
      );
      expect(
        app.resolver
            .ports(app.sheet.devices.single)
            .map((p) => p.signal)
            .toSet(),
        {'24V'},
      );
      expect(app.project.components.single.electrical!.terminals, hasLength(1));
      app.addContinuation(position: const Vec2(550, 300), label: 'INPUT');
      app.connect(
        TerminalRef(deviceId: device.id, portId: 'top'),
        ContinuationRef(markerId: app.sheet.continuations.single.id),
      );
      await tester.pumpAndSettle();
      await ui.click(tester, 'Směry svorky (1–4)…');
      await tester.tap(find.byKey(const ValueKey('terminal-symbol-side-top')));
      await ui.click(tester, 'Uložit');
      expect(
        (app.sheet.devices.single.symbol as TerminalSymbolSpec).sides,
        contains(PortSide.top),
      );
      expect(
        find.textContaining('Připojený směr nelze odstranit'),
        findsOneWidget,
      );
      final hover =
          resolveWireHoverInfo(
            resolver: app.resolver,
            sheetId: 's',
            wireId: app.sheet.wires.single.id,
          )!;
      expect(hover.label, contains('+CELL-X1:1:A'));
      final export = ProjectExportService();
      final svg = export.svg(app.project);
      final symbol =
          RegExp(
            '<g data-device="${device.id}"[^>]*>(.*?)</g>',
            dotAll: true,
          ).firstMatch(svg)!.group(1)!;
      expect(RegExp('<circle').allMatches(symbol), hasLength(1));
      expect(RegExp('<line').allMatches(symbol), hasLength(4));
      expect(symbol, isNot(contains('<rect')));
      expect(svg, contains('+CELL-X1'));
      final pdf = await tester.runAsync(() => export.pdf(app.project));
      expect(ascii.decode(pdf!.take(4).toList()), '%PDF');
      await ui.click(tester, 'Další zobrazení tohoto kusu…');
      expect(
        find.text('Průchozí svorka · jedna vodivá funkce'),
        findsOneWidget,
      );
      await ui.click(tester, 'Použít');
      expect(app.sheet.devices, hasLength(2));
      expect(app.sheet.devices.last.symbol, isA<TerminalSymbolSpec>());
      expect(app.sheet.devices.last.mode, OccurrenceMode.reference);
      expect(app.project.components, hasLength(1));
      expect(app.bom.articles.single.requiredTotal.knownBaseUnits, 1);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 500));
    },
  );

  testWidgets(
    'direction dialog stays with its owner when another project becomes active',
    (tester) async {
      final app = EditorController(
        initialProject: EcadProject(
          id: 'p',
          name: 'A',
          pages: [Sheet(id: 's', name: 'A', number: '01')],
        ),
        persistence: ui.MemoryPersistence(),
      );
      addTearDown(app.dispose);
      app.placeTerminal(const Vec2(550, 390));
      await ui.mountEditor(tester, app);
      await ui.doubleClickSymbol(tester);
      await ui.click(tester, 'Směry svorky (1–4)…');
      await tester.tap(
        find.byKey(const ValueKey('terminal-symbol-side-right')),
      );
      final b = EditorController(
        initialProject: app.project.copyWith(name: 'B'),
        persistence: ui.MemoryPersistence(),
      );
      final workspace =
          tester
              .widget<EditorWorkspace>(find.byType(EditorWorkspace))
              .workspace!;
      workspace.add(b);
      await tester.pumpAndSettle();
      expect(find.byType(TerminalSymbolDialog), findsOneWidget);
      await ui.click(tester, 'Uložit');
      expect(
        (app.sheet.devices.single.symbol as TerminalSymbolSpec).sides,
        hasLength(3),
      );
      expect(
        (b.sheet.devices.single.symbol as TerminalSymbolSpec).sides,
        hasLength(2),
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 500));
    },
  );

  testWidgets(
    'structure view sorts exact local names and keeps unassigned pages reachable',
    (tester) async {
      final context = StructureContext(locationPath: ['LAB/1']);
      final pages = [
        for (final number in ['10', '2', '1', '01'])
          Sheet(
            id: 's$number',
            number: number,
            name: 'Page',
            structure: context,
          ),
        Sheet(id: 'unassigned', number: '00', name: 'Unassigned'),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: StructureTree<Sheet>(
                items: pages,
                contextFor: (s) => s.structure,
                compare: (a, b) {
                  final n = naturalCompare(a.number, b.number);
                  return n != 0 ? n : a.number.compareTo(b.number);
                },
                onRename: (_, _) {},
                leaf: (s) => Text(fullPageDesignation(s), key: ValueKey(s.id)),
              ),
            ),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('unassigned')), findsOneWidget);
      final labels =
          tester
              .widgetList<Text>(find.byType(Text))
              .map((t) => t.data)
              .whereType<String>()
              .where((s) => s.startsWith('+LAB/1/'))
              .toList();
      expect(labels, ['+LAB/1/01', '+LAB/1/1', '+LAB/1/2', '+LAB/1/10']);
      expect(pages.map((p) => p.number), ['10', '2', '1', '01', '00']);
    },
  );
}
