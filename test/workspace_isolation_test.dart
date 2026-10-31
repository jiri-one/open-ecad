import 'dart:async';
import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/app/controller.dart';
import 'package:open_ecad/app/workspace.dart';
import 'package:open_ecad/app/workspace_controller.dart';
import 'package:open_ecad/editor/schematic_canvas.dart';
import 'package:open_ecad/services/project_persistence.dart';
import 'package:shared_preferences/shared_preferences.dart';

EcadProject syntheticProject(String name) {
  final breaker = createBuiltinComponent(
    componentId: 'component_q',
    deviceId: 'q',
    kind: DeviceKind.breaker,
    designation: '-Q1',
    position: const Vec2(400, 300),
  );
  final contactor = createBuiltinComponent(
    componentId: 'component_k',
    deviceId: 'k',
    kind: DeviceKind.contactor,
    designation: '-K1',
    position: const Vec2(400, 450),
  );
  return EcadProject(
    id: 'identical_project',
    name: name,
    components: [breaker.component, contactor.component],
    pages: [
      Sheet(
        id: 'identical_sheet',
        name: 'Synthetic sheet',
        number: '01',
        devices: [breaker.device, contactor.device],
      ),
    ],
  );
}

class MemoryPersistence extends ProjectPersistence {
  final opened = Completer<LoadedProject>();
  final recovery = Completer<WorkingCopy?>();
  int recoveryLoads = 0;
  @override
  Future<void> saveWorkingCopy(WorkingCopy copy) async {}
  @override
  Future<LoadedProject> loadPath(String path) => opened.future;
  @override
  Future<WorkingCopy?> loadAutosave({String? sessionId}) {
    recoveryLoads++;
    return recovery.future;
  }
}

void screen(WidgetTester tester) {
  tester.view.physicalSize = const Size(1600, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Offset point(WidgetTester tester, Vec2 world, EditorController app) =>
    tester.getRect(find.byType(SchematicCanvas)).center +
    Offset(world.x - app.sheet.width / 2, world.y - app.sheet.height / 2);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('concurrent recovery keeps one owner and its history', () async {
    final persistence = MemoryPersistence();
    final a = EditorController(
      initialProject: syntheticProject('A'),
      persistence: persistence,
    );
    final workspace = WorkspaceController(a);
    addTearDown(() {
      workspace.dispose();
      a.dispose();
    });
    final one = workspace.restore('same_recovery');
    final two = workspace.restore('same_recovery');
    expect(persistence.recoveryLoads, 2);
    persistence.recovery.complete(
      WorkingCopy(syntheticProject('Recovered'), sessionId: 'same_recovery'),
    );
    expect(await Future.wait([one, two]), [true, true]);
    final duplicates =
        workspace.documents
            .where((d) => d.documentSessionId == 'same_recovery')
            .toList();
    expect(duplicates, hasLength(1));
    expect(
      workspace.tabs.where((t) => t.sessionId == 'same_recovery'),
      hasLength(1),
    );
    expect(
      workspace.document(workspace.activeTab!.sessionId),
      same(workspace.active),
    );
    duplicates.last.renameProject('Second recovery edited');
    workspace.activate(workspace.activeTab!);
    expect(workspace.active.project.name, 'Second recovery edited');
  });

  testWidgets(
    'wire gesture belongs to its session even with identical sheet and device IDs',
    (tester) async {
      screen(tester);
      final persistence = MemoryPersistence();
      final seed = syntheticProject('A');
      final a = EditorController(initialProject: seed, persistence: persistence)
        ..setMode(CanvasMode.wire);
      final b = EditorController(
        initialProject: seed.copyWith(name: 'B'),
        persistence: persistence,
      )..setMode(CanvasMode.wire);
      addTearDown(a.dispose);
      await tester.pumpWidget(OpenEcadApp(controller: a));
      final workspace =
          tester
              .widget<EditorWorkspace>(find.byType(EditorWorkspace))
              .workspace!;
      workspace.add(b);
      workspace.openSheet(a, a.activeSheetId);
      await tester.pumpAndSettle();
      a.viewport.reset();
      await tester.pump();
      final from = worldPortPosition(a.sheet.deviceById('q')!, 'out');
      final to = worldPortPosition(a.sheet.deviceById('k')!, 'in');
      await tester.tapAt(point(tester, from, a));
      await tester.pump();
      expect(a.sheet.wires, isEmpty);
      await tester.tap(find.text('B · 01 Synthetic sheet'));
      await tester.pumpAndSettle();
      expect(workspace.active, same(b));
      b.viewport.reset();
      await tester.pump();
      expect(b.sheet.wires, isEmpty);
      await tester.tapAt(point(tester, to, b));
      await tester.pumpAndSettle();
      expect(a.sheet.wires, isEmpty);
      expect(b.sheet.wires, isEmpty);
      await tester.tapAt(point(tester, from, b));
      await tester.pumpAndSettle();
      expect(b.sheet.wires, hasLength(1));
      expect(
        b.sheet.wires.single.to,
        const TerminalRef(deviceId: 'q', portId: 'out'),
      );
      expect(
        b.sheet.wires.single.from,
        const TerminalRef(deviceId: 'k', portId: 'in'),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 500));
    },
  );

  testWidgets('pending Open cannot retarget the project rename dialog', (
    tester,
  ) async {
    screen(tester);
    final persistence = MemoryPersistence();
    final a = EditorController(
      initialProject: syntheticProject('A'),
      persistence: persistence,
    );
    addTearDown(a.dispose);
    await tester.pumpWidget(OpenEcadApp(controller: a));
    await tester.pumpAndSettle();
    final workspace =
        tester.widget<EditorWorkspace>(find.byType(EditorWorkspace)).workspace!;
    final opening = workspace.open(path: 'synthetic-b.oecad');
    await tester.tap(find.text('A').first);
    await tester.pumpAndSettle();
    expect(find.text('Název projektu'), findsOneWidget);
    await tester.enterText(
      find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == 'Název',
      ),
      'A renamed',
    );
    persistence.opened.complete(LoadedProject(syntheticProject('B')));
    expect(await opening, isTrue);
    await tester.pumpAndSettle();
    final b = workspace.active;
    expect(b.project.name, 'B');
    await tester.tap(find.text('Uložit název'));
    await tester.pumpAndSettle();
    expect(a.project.name, 'A renamed');
    expect(b.project.name, 'B');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 500));
  });

  for (final action in ['sheet', 'add']) {
    testWidgets('pending Open keeps $action dialog on its original owner', (
      tester,
    ) async {
      screen(tester);
      final persistence = MemoryPersistence();
      final seed = syntheticProject('A');
      final a = EditorController(
        initialProject: seed.copyWith(
          pages: [
            ...seed.pages,
            Sheet(id: 'other', name: 'Other', number: '02'),
          ],
        ),
        persistence: persistence,
      );
      addTearDown(a.dispose);
      await tester.pumpWidget(OpenEcadApp(controller: a));
      await tester.pumpAndSettle();
      final workspace =
          tester
              .widget<EditorWorkspace>(find.byType(EditorWorkspace))
              .workspace!;
      final opening = workspace.open(path: 'synthetic-b.oecad');
      if (action == 'sheet') {
        final tab = find.text('A · 01 Synthetic sheet');
        await tester.tap(tab);
        await tester.pump(const Duration(milliseconds: 60));
        await tester.tap(tab);
      } else {
        await tester.tap(find.byTooltip('Přidat list').last);
      }
      await tester.pumpAndSettle();
      final field = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      );
      await tester.enterText(field, 'Owned by A');
      a.setSheet('other');
      persistence.opened.complete(LoadedProject(syntheticProject('B')));
      expect(await opening, isTrue);
      final b = workspace.active;
      await tester.pumpAndSettle();
      await tester.tap(
        find.text(action == 'sheet' ? 'Uložit název' : 'Vytvořit list'),
      );
      await tester.pumpAndSettle();
      expect(b.project.pages, hasLength(1));
      expect(b.sheet.name, 'Synthetic sheet');
      expect(a.project.sheetById('other')!.name, 'Other');
      expect(
        a.project.pages.where((s) => s.name == 'Owned by A'),
        hasLength(1),
      );
      expect(a.project.pages, hasLength(action == 'sheet' ? 2 : 3));
      expect(workspace.active, same(b));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 500));
    });
  }

  testWidgets('closed dialog owner cannot rename its replacement session', (
    tester,
  ) async {
    screen(tester);
    final a = EditorController(
      initialProject: syntheticProject('A'),
      persistence: MemoryPersistence(),
    );
    addTearDown(a.dispose);
    await tester.pumpWidget(OpenEcadApp(controller: a));
    await tester.pumpAndSettle();
    final workspace =
        tester.widget<EditorWorkspace>(find.byType(EditorWorkspace)).workspace!;
    await tester.tap(find.text('A').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Closed owner');
    workspace.closeDocument(a);
    final replacement = workspace.active;
    final before = replacement.project;
    await tester.tap(find.text('Uložit název'));
    await tester.pumpAndSettle();
    expect(replacement.project, same(before));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets(
    'tabs discard all canvas-local state including wire selection and active drag',
    (tester) async {
      screen(tester);
      final seed = syntheticProject('A');
      final sheet = seed.pages.single.copyWith(
        wires: [
          Wire(
            id: 'wire',
            from: const TerminalRef(deviceId: 'q', portId: 'out'),
            to: const TerminalRef(deviceId: 'k', portId: 'in'),
          ),
        ],
      );
      final a = EditorController(
        initialProject: seed.copyWith(pages: [sheet]),
        persistence: MemoryPersistence(),
      );
      final b = EditorController(
        initialProject: a.project.copyWith(name: 'B'),
        persistence: MemoryPersistence(),
      );
      addTearDown(a.dispose);
      await tester.pumpWidget(OpenEcadApp(controller: a));
      final workspace =
          tester
              .widget<EditorWorkspace>(find.byType(EditorWorkspace))
              .workspace!;
      workspace.add(b);
      workspace.openSheet(a, a.activeSheetId);
      await tester.pumpAndSettle();
      a.viewport.reset();
      await tester.pump();
      final oldState = tester.state(find.byType(SchematicCanvas));
      await tester.tapAt(point(tester, const Vec2(400, 380), a));
      await tester.pump();
      await tester.tap(find.text('B · 01 Synthetic sheet'));
      await tester.pumpAndSettle();
      expect(oldState.mounted, isFalse);
      expect(tester.state(find.byType(SchematicCanvas)), isNot(same(oldState)));
      b.viewport.reset();
      await tester.pump();
      await tester.tapAt(point(tester, const Vec2(700, 500), b));
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pump();
      expect(b.sheet.wires, hasLength(1));
      final bState = tester.state(find.byType(SchematicCanvas));
      final drag = await tester.startGesture(
        point(tester, b.sheet.devices.first.position, b),
      );
      await drag.moveBy(const Offset(70, 0));
      await tester.pump();
      final before = a.project;
      workspace.openSheet(a, a.activeSheetId);
      await tester.pump();
      expect(bState.mounted, isFalse);
      await drag.up();
      await tester.pumpAndSettle();
      expect(a.project, same(before));
      expect(b.sheet.devices.first.position, sheet.devices.first.position);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 500));
    },
  );
}
