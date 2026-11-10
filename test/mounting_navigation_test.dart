import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/app/controller.dart';
import 'package:open_ecad/app/workspace.dart';
import 'package:open_ecad/editor/schematic_canvas.dart' show CanvasMode;
import 'package:open_ecad/services/mounting_annotations.dart';
import 'package:open_ecad/services/report_layout.dart';
import 'package:open_ecad/services/project_persistence.dart';
import 'package:open_ecad/widgets/report_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Persistence extends ProjectPersistence {
  @override
  Future<String> saveWorkingCopy(
    WorkingCopy copy, {
    EncodedProject? encoded,
  }) async => 'memory';
}

EcadProject navigationProject({bool ambiguous = false, bool missing = false}) {
  final relay = createBuiltinComponent(
    componentId: 'relay',
    deviceId: 'main',
    kind: DeviceKind.coil,
    designation: '-K1',
    position: const Vec2(800, 500),
  );
  final terminals = [
    for (var i = 1; i <= 2; i++)
      createTerminalComponent(
        componentId: 'terminal-$i',
        deviceId: 'symbol-$i',
        stripId: 'strip',
        number: '$i',
        position: Vec2(400.0 * i, 300),
      ),
  ];
  return EcadProject(
    id: 'navigation',
    name: 'Synthetic navigation',
    terminalStrips: [
      TerminalStrip(
        id: 'strip',
        reference: ComponentReference(localDesignation: 'X1'),
      ),
    ],
    components: [
      relay.component.copyWith(
        mountingSizeOverrideMm: const DimensionsMm(width: 40, height: 60),
      ),
      for (final terminal in terminals)
        terminal.component.copyWith(
          mountingSizeOverrideMm: const DimensionsMm(width: 6, height: 55),
        ),
    ],
    mountingLayouts: [
      MountingLayout(
        id: 'layout',
        name: 'Panel',
        widthMm: 300,
        heightMm: 200,
        placements: const [
          MountingPlacement(
            id: 'placement-relay',
            componentId: 'relay',
            centerMm: Vec2(60, 80),
          ),
          MountingPlacement(
            id: 'placement-1',
            componentId: 'terminal-1',
            centerMm: Vec2(170, 110),
          ),
          MountingPlacement(
            id: 'placement-2',
            componentId: 'terminal-2',
            centerMm: Vec2(190, 110),
          ),
        ],
      ),
    ],
    pages: [
      Sheet(
        id: 'mounting',
        name: 'Panel',
        number: '1',
        type: SheetType.cabinetLayout,
        mountingView: const MountingView(
          layoutId: 'layout',
          viewport: RectUnits(x: 20, y: 60, width: 1000, height: 650),
        ),
      ),
      Sheet(
        id: 'auxiliary',
        name: 'Auxiliary',
        number: '2',
        devices: [
          relay.device.copyWith(
            id: 'aux',
            position: const Vec2(300, 200),
            mode: ambiguous ? OccurrenceMode.wiring : OccurrenceMode.reference,
          ),
        ],
      ),
      Sheet(
        id: 'schematic',
        name: 'Main function',
        number: '3',
        devices: [
          if (!missing) relay.device.copyWith(isMainFunction: !ambiguous),
        ],
      ),
      for (var i = 0; i < terminals.length; i++)
        Sheet(
          id: 'terminals-$i',
          name: 'Terminal ${i + 1}',
          number: '${i + 4}',
          devices: [terminals[i].device],
        ),
      Sheet(
        id: 'report',
        name: 'Terminal and component plan',
        number: '6',
        type: SheetType.billOfMaterials,
        report: const BomTableSpec(kind: BomReportKind.components),
      ),
    ],
  );
}

Future<EditorController> mount(
  WidgetTester tester, {
  EcadProject? project,
  String sheetId = 'mounting',
}) async {
  tester.view.physicalSize = const Size(1700, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final app = EditorController(
    initialProject: project ?? navigationProject(),
    persistence: _Persistence(),
  );
  app.setSheet(sheetId);
  addTearDown(app.dispose);
  await tester.pumpWidget(OpenEcadApp(controller: app));
  await tester.pumpAndSettle();
  return app;
}

Offset placementPoint(
  WidgetTester tester,
  EditorController app,
  String id, {
  bool label = false,
}) {
  final surface = tester.renderObject<RenderBox>(
    find.byKey(const ValueKey('mounting-surface')),
  );
  final sheet = app.sheet;
  final scale = surface.size.width / sheet.width;
  final placement = app.activeLayout!.placements.singleWhere((p) => p.id == id);
  final point =
      label
          ? layoutMountingAnnotations(
            app.resolver,
            sheet,
          ).singleWhere((a) => a.placementId == id).bounds.center
          : (() {
            final point = MountingTransform(
              sheet,
              sheet.mountingView!,
            ).toSheet(placement.centerMm);
            return Offset(point.x, point.y);
          })();
  return surface.localToGlobal(point * scale);
}

dynamic painter(WidgetTester tester, String name) =>
    tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .firstWhere((w) => w.painter.runtimeType.toString() == name)
        .painter;

Future<void> finish(WidgetTester tester) async {
  expect(tester.takeException(), isNull);
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(milliseconds: 500));
}

Offset _navigationPoint(WidgetTester tester, EditorController app) {
  if (app.sheet.type != SheetType.billOfMaterials) {
    return placementPoint(tester, app, 'placement-relay');
  }
  final layout = layoutReport(app.project, app.sheet);
  final page = layout.pages.first;
  final target = layoutReportNavigationLinks(
    app.resolver,
    layout,
    page,
  ).singleWhere((link) => link.target.device.id == 'symbol-2');
  final surface = tester.renderObject<RenderBox>(
    find.byKey(const ValueKey('report-surface')),
  );
  return surface.localToGlobal(
    target.bounds.center * (surface.size.width / page.sizeMm.width),
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final sheet in ['mounting', 'report']) {
    for (final restore in [false, true]) {
      for (final rebuild in [false, true]) {
        testWidgets(
          '$sheet press stays canceled after project switch, restore=$restore rebuild=$rebuild',
          (tester) async {
            final source = await mount(tester, sheetId: sheet);
            final workspace =
                tester
                    .widget<EditorWorkspace>(find.byType(EditorWorkspace))
                    .workspace!;
            final original = source.project;
            final mouse = await tester.createGesture(
              kind: PointerDeviceKind.mouse,
            );
            await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
            await mouse.down(_navigationPoint(tester, source));
            final other = EditorController(
              initialProject: navigationProject(),
              persistence: _Persistence(),
            );
            workspace.add(other);
            if (restore) workspace.openSheet(source, sheet);
            if (rebuild) await tester.pump();
            await mouse.up();
            await tester.pumpAndSettle();
            await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
            expect(workspace.active, same(restore ? source : other));
            expect(source.sheet.id, sheet);
            expect(source.selectedIds, isEmpty);
            expect(other.sheet.id, 'mounting');
            expect(other.selectedIds, isEmpty);
            expect(source.project, same(original));
            expect(source.canUndo, isFalse);
            await mouse.removePointer();
            await finish(tester);
          },
        );
      }
    }
    for (final change in [
      'tool',
      'sheet',
      'revision',
      'focus',
      'focus-return',
    ]) {
      testWidgets('$sheet press stays canceled after $change changes', (
        tester,
      ) async {
        final app = await mount(tester, sheetId: sheet);
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await mouse.down(_navigationPoint(tester, app));
        switch (change) {
          case 'tool':
            app.setMode(CanvasMode.pan);
            app.setMode(CanvasMode.select);
          case 'sheet':
            app.setSheet('schematic');
            app.setSheet(sheet);
          case 'revision':
            app.renameProject('Changed while pressed');
            app.undo();
          case 'focus' || 'focus-return':
            final previousFocus = FocusManager.instance.primaryFocus;
            final fieldFocus =
                tester
                    .widget<EditableText>(find.byType(EditableText).last)
                    .focusNode;
            fieldFocus.requestFocus();
            FocusManager.instance.applyFocusChangesIfNeeded();
            expect(fieldFocus.hasFocus, isTrue);
            if (change == 'focus-return') {
              if (previousFocus is FocusScopeNode) {
                previousFocus.requestScopeFocus();
              } else {
                previousFocus!.requestFocus();
              }
              FocusManager.instance.applyFocusChangesIfNeeded();
              expect(FocusManager.instance.primaryFocus, same(previousFocus));
            }
        }
        await mouse.up();
        await tester.pumpAndSettle();
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        expect(app.sheet.id, sheet);
        expect(app.selectedIds, isEmpty);
        expect(app.canUndo, isFalse);
        await mouse.removePointer();
        await finish(tester);
      });
    }
  }
  for (final id in ['placement-relay', 'placement-2']) {
    for (final label in [false, true]) {
      testWidgets(
        'mounting Ctrl link $id label=$label reveals the exact destination',
        (tester) async {
          final app = await mount(tester);
          final before = app.project;
          if (label) {
            await tester.tap(find.byType(TextField).last);
            await tester.pump();
          }
          final mouse = await tester.createGesture(
            kind: PointerDeviceKind.mouse,
            pointer: 1,
          );
          final point = placementPoint(tester, app, id, label: label);
          await mouse.addPointer(location: point - const Offset(1, 0));
          await mouse.moveTo(point);
          await tester.pump();
          expect(painter(tester, '_MountingPainter').activeLink, id);
          expect(
            tester.binding.mouseTracker.debugDeviceActiveCursor(1),
            isNot(SystemMouseCursors.click),
          );
          await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
          await tester.pump();
          expect(
            tester.binding.mouseTracker.debugDeviceActiveCursor(1),
            SystemMouseCursors.click,
          );
          await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
          await tester.pump();
          expect(painter(tester, '_MountingPainter').activeLink, id);
          await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
          await mouse.down(point);
          await mouse.up();
          await tester.pumpAndSettle();
          await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
          await tester.pump();
          final target = id == 'placement-relay' ? 'main' : 'symbol-2';
          expect(
            app.sheet.id,
            id == 'placement-relay' ? 'schematic' : 'terminals-1',
          );
          expect(app.selectedIds, {target});
          expect(
            app.viewport.deviceFocus,
            app.sheet.deviceById(target)!.position,
          );
          expect(find.byKey(const ValueKey('device-focus')), findsOneWidget);
          expect(app.project, same(before));
          expect(app.canUndo, isFalse);
          await mouse.removePointer();
          await finish(tester);
        },
      );
    }
  }
  for (final missing in [false, true]) {
    testWidgets(
      'unresolved mounting targets have no hover or navigation, missing=$missing',
      (tester) async {
        final app = await mount(
          tester,
          project: navigationProject(ambiguous: !missing, missing: missing),
        );
        final point = placementPoint(tester, app, 'placement-relay');
        final mouse = await tester.createGesture(
          kind: PointerDeviceKind.mouse,
          pointer: 1,
        );
        await mouse.addPointer(location: point);
        await mouse.moveTo(point);
        await tester.pump();
        expect(painter(tester, '_MountingPainter').activeLink, isNull);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();
        expect(
          tester.binding.mouseTracker.debugDeviceActiveCursor(1),
          isNot(SystemMouseCursors.click),
        );
        await mouse.down(point);
        await mouse.up();
        await tester.pumpAndSettle();
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump(const Duration(milliseconds: 350));
        expect(app.sheet.id, 'mounting');
        expect(app.selectedIds, {'placement-relay'});
        expect(app.canUndo, isFalse);
        await mouse.removePointer();
        await finish(tester);
      },
    );
  }
  testWidgets(
    'ordinary mounting clicks and drags still select and move; Ctrl drag does not navigate',
    (tester) async {
      final app = await mount(tester);
      var point = placementPoint(tester, app, 'placement-relay');
      await tester.tapAt(point);
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(app.selectedIds, {'placement-relay'});
      final before = app.activeLayout!.placements.first.centerMm;
      await tester.dragFrom(point, const Offset(60, 30));
      await tester.pumpAndSettle();
      expect(app.activeLayout!.placements.first.centerMm, isNot(before));
      expect(app.sheet.id, 'mounting');
      expect(app.canUndo, isTrue);
      app.undo();
      await tester.pumpAndSettle();
      point = placementPoint(tester, app, 'placement-relay');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      final drag = await tester.startGesture(
        point,
        kind: PointerDeviceKind.mouse,
      );
      await drag.moveBy(const Offset(25, 0));
      await drag.moveTo(point);
      await drag.up();
      await tester.pumpAndSettle();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(app.sheet.id, 'mounting');
      expect(app.activeLayout!.placements.first.centerMm, before);
      expect(app.canUndo, isFalse);
      await finish(tester);
    },
  );
  testWidgets('mounting hover clears on exit and after switching sheets', (
    tester,
  ) async {
    final app = await mount(tester);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    final point = placementPoint(tester, app, 'placement-relay');
    await mouse.addPointer(location: point);
    await mouse.moveTo(point);
    await tester.pump();
    expect(painter(tester, '_MountingPainter').activeLink, 'placement-relay');
    await mouse.moveTo(const Offset(5, 5));
    await tester.pump();
    expect(painter(tester, '_MountingPainter').activeLink, isNull);
    app.setSheet('schematic');
    await tester.pumpAndSettle();
    app.setSheet('mounting');
    await tester.pumpAndSettle();
    expect(painter(tester, '_MountingPainter').activeLink, isNull);
    await mouse.removePointer();
    await finish(tester);
  });
  testWidgets(
    'a component report terminal row goes to its exact schematic terminal',
    (tester) async {
      final app = await mount(tester, sheetId: 'report');
      final before = app.project;
      final layout = layoutReport(app.project, app.sheet);
      final link = layoutReportNavigationLinks(
        app.resolver,
        layout,
        layout.pages.first,
      ).singleWhere((l) => l.target.device.id == 'symbol-2');
      final surface = tester.renderObject<RenderBox>(
        find.byKey(const ValueKey('report-surface')),
      );
      final scale = surface.size.width / layout.pages.first.sizeMm.width;
      final point = surface.localToGlobal(link.bounds.center * scale);
      await tester.tap(find.byType(TextField).last);
      await tester.pump();
      final mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
        pointer: 1,
      );
      await mouse.addPointer(location: point);
      await mouse.moveTo(point);
      await tester.pump();
      expect(painter(tester, '_ReportPainter').activeLink, link.bounds);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(
        tester.binding.mouseTracker.debugDeviceActiveCursor(1),
        SystemMouseCursors.click,
      );
      await mouse.down(point);
      await mouse.up();
      await tester.pumpAndSettle();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(find.byType(ReportView), findsNothing);
      expect(app.sheet.id, 'terminals-1');
      expect(app.selectedIds, {'symbol-2'});
      expect(app.viewport.deviceFocus, const Vec2(800, 300));
      expect(app.project, same(before));
      await mouse.removePointer();
      await finish(tester);
    },
  );
}
