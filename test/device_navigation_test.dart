// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:math' as math;

import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/app/controller.dart';
import 'package:open_ecad/app/workspace.dart';
import 'package:open_ecad/app/workspace_controller.dart';
import 'package:open_ecad/editor/schematic_canvas.dart';
import 'package:open_ecad/services/project_persistence.dart';
import 'package:open_ecad/services/schematic_annotations.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MemoryPersistence extends ProjectPersistence {
  @override
  Future<void> saveWorkingCopy(WorkingCopy copy) async {}
}

EcadProject _project() {
  final seed = createBuiltinComponent(
    componentId: 'supply',
    deviceId: 'source',
    kind: DeviceKind.supply,
    designation: '-P1',
    position: const Vec2(1000, 750),
  );
  return EcadProject(
    id: 'project',
    name: 'Synthetic navigation',
    components: [seed.component],
    pages: [
      Sheet(
        id: 'first',
        name: 'First',
        number: '1',
        width: 2400,
        height: 1600,
        devices: [
          seed.device,
          seed.device.copyWith(
            id: 'same-sheet',
            mode: OccurrenceMode.reference,
            position: const Vec2(2200, 1400),
          ),
        ],
      ),
      Sheet(
        id: 'second',
        name: 'Second',
        number: '1',
        width: 3300,
        height: 2200,
        structure: StructureContext(locationPath: ['OTHER']),
        devices: [
          seed.device.copyWith(
            id: 'other-sheet',
            mode: OccurrenceMode.reference,
            position: const Vec2(2800, 1800),
          ),
          seed.device.copyWith(
            id: 'other-place',
            mode: OccurrenceMode.reference,
            position: const Vec2(500, 500),
          ),
        ],
      ),
    ],
  );
}

Future<WorkspaceController> _mount(
  WidgetTester tester,
  EditorController app,
) async {
  tester.view.physicalSize = const Size(1700, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(app.dispose);
  await tester.pumpWidget(OpenEcadApp(controller: app));
  await tester.pumpAndSettle();
  app.viewport.reset();
  await tester.pump();
  return tester
      .widget<EditorWorkspace>(find.byType(EditorWorkspace))
      .workspace!;
}

Offset _point(WidgetTester tester, EditorController app, Vec2 point) =>
    tester.getTopLeft(find.byType(SchematicCanvas)) +
    app.viewport.worldToLocal(point)!;

Offset _link(WidgetTester tester, EditorController app, String targetId) {
  final reference = layoutDeviceCrossReferences(
    app.resolver,
    app.sheet.deviceById('source')!,
  ).singleWhere((r) => r.target.device.id == targetId);
  return _point(
    tester,
    app,
    Vec2(reference.bounds.center.dx, reference.bounds.center.dy),
  );
}

Future<void> _finish(WidgetTester tester) async {
  expect(tester.takeException(), isNull);
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(milliseconds: 500));
}

dynamic _scenePainter(WidgetTester tester) =>
    tester
        .widgetList<CustomPaint>(
          find.descendant(
            of: find.byType(SchematicCanvas),
            matching: find.byType(CustomPaint),
          ),
        )
        .firstWhere(
          (w) => w.painter.runtimeType.toString() == '_SchematicPainter',
        )
        .painter;

Future<void> _middleClick(
  TestGesture mouse,
  Offset point,
  int milliseconds,
) async {
  await mouse.down(point, timeStamp: Duration(milliseconds: milliseconds));
  await mouse.up(timeStamp: Duration(milliseconds: milliseconds + 30));
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final returnToSource in [false, true]) {
    testWidgets(
      'a pending link is canceled across a project switch (return=$returnToSource)',
      (tester) async {
        final app = EditorController(
          initialProject: _project(),
          persistence: _MemoryPersistence(),
        );
        final workspace = await _mount(tester, app);
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await mouse.down(_link(tester, app, 'other-sheet'));
        final other = EditorController(
          initialProject: _project(),
          persistence: _MemoryPersistence(),
        );
        workspace.add(other);
        if (returnToSource) workspace.openSheet(app, 'first');
        await mouse.up();
        await tester.pumpAndSettle();
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        for (final document in [app, other]) {
          expect(document.sheet.id, 'first');
          expect(document.selectedIds, isEmpty);
          expect(document.dirty, isFalse);
          expect(document.canUndo, isFalse);
        }
        await mouse.removePointer();
        await _finish(tester);
      },
    );
  }

  for (final wheel in [true, false]) {
    testWidgets(
      'navigation retains zoom changed before the next frame (wheel=$wheel)',
      (tester) async {
        final app = EditorController(
          initialProject: _project(),
          persistence: _MemoryPersistence(),
        );
        await _mount(tester, app);
        if (wheel) {
          await tester.sendEventToBinding(
            PointerScrollEvent(
              kind: PointerDeviceKind.mouse,
              position: tester.getCenter(find.byType(SchematicCanvas)),
              scrollDelta: Offset(0, -math.log(1.2) / .0015),
            ),
          );
        } else {
          app.viewport.zoomIn();
        }
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.tapAt(_link(tester, app, 'other-sheet'));
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();
        expect(app.selectedIds, {'other-sheet'});
        expect(app.viewport.zoom, closeTo(1.2, .001));
        expect(app.viewport.deviceFocus, const Vec2(2800, 1800));
        expect(app.canUndo, isFalse);
        await _finish(tester);
      },
    );
  }

  for (final target in ['same-sheet', 'other-sheet', 'other-place']) {
    testWidgets(
      'Ctrl link reveals the exact occurrence $target without edits',
      (tester) async {
        final app = EditorController(
          initialProject: _project(),
          persistence: _MemoryPersistence(),
        );
        final workspace = await _mount(tester, app);
        final before = app.project;
        final destination = app.resolver
            .otherOccurrences(app.sheet.deviceById('source')!)
            .singleWhere((o) => o.device.id == target);
        final mouse = await tester.createGesture(
          kind: PointerDeviceKind.mouse,
          pointer: 1,
        );
        final link = _link(tester, app, target);
        await mouse.addPointer(location: link);
        await mouse.moveTo(link);
        await tester.pump();
        final dynamic painter =
            tester
                .widgetList<CustomPaint>(
                  find.descendant(
                    of: find.byType(SchematicCanvas),
                    matching: find.byType(CustomPaint),
                  ),
                )
                .firstWhere(
                  (w) =>
                      w.painter.runtimeType.toString() == '_SchematicPainter',
                )
                .painter;
        expect(painter.activeReference.target.device.id, target);
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
        await mouse.down(link);
        await mouse.up();
        await tester.pumpAndSettle();
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();
        expect(app.sheet.id, destination.sheet.id);
        expect(
          workspace.activeTab,
          SheetTab(app.documentSessionId, destination.sheet.id),
        );
        expect(app.selectedIds, {target});
        expect(app.viewport.deviceFocus, destination.device.position);
        expect(
          app.viewport.worldViewport!.center.dx,
          closeTo(destination.device.position.x, .001),
        );
        expect(
          app.viewport.worldViewport!.center.dy,
          closeTo(destination.device.position.y, .001),
        );
        expect(app.viewport.zoom, 1);
        expect(app.project, same(before));
        expect(app.dirty, isFalse);
        expect(app.canUndo, isFalse);
        await mouse.removePointer();
        await _finish(tester);
      },
    );
  }

  testWidgets(
    'Ctrl cursor updates on release and a normal link click stays on the sheet',
    (tester) async {
      final app = EditorController(
        initialProject: _project(),
        persistence: _MemoryPersistence(),
      );
      await _mount(tester, app);
      final mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
        pointer: 1,
      );
      final link = _link(tester, app, 'other-sheet');
      await mouse.addPointer(location: link);
      await mouse.moveTo(link);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlRight);
      await tester.pump();
      expect(
        tester.binding.mouseTracker.debugDeviceActiveCursor(1),
        SystemMouseCursors.click,
      );
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlRight);
      await tester.pump();
      expect(
        tester.binding.mouseTracker.debugDeviceActiveCursor(1),
        isNot(SystemMouseCursors.click),
      );
      expect(_scenePainter(tester).activeReference, isNotNull);
      await mouse.moveTo(const Offset(5, 5));
      await tester.pump();
      expect(_scenePainter(tester).activeReference, isNull);
      await mouse.moveTo(link);
      await tester.pump();
      expect(_scenePainter(tester).activeReference, isNotNull);
      await tester.tap(find.byType(TextField).last);
      await tester.pump();
      expect(_scenePainter(tester).activeReference, isNull);
      await mouse.down(link);
      await mouse.up();
      await tester.pumpAndSettle();
      expect(app.sheet.id, 'first');
      expect(app.canUndo, isFalse);
      await mouse.removePointer();
      await _finish(tester);
    },
  );

  testWidgets(
    'navigation remains in the active document even with identical project IDs',
    (tester) async {
      final app = EditorController(
        initialProject: _project(),
        persistence: _MemoryPersistence(),
      );
      final workspace = await _mount(tester, app);
      final other = EditorController(
        initialProject: _project(),
        persistence: _MemoryPersistence(),
      );
      workspace.add(other);
      workspace.openSheet(app, 'first');
      await tester.pumpAndSettle();
      app.viewport.reset();
      await tester.pump();
      final otherBefore = other.project;
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.tapAt(_link(tester, app, 'other-sheet'));
      await tester.pumpAndSettle();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(workspace.active, same(app));
      expect(app.selectedIds, {'other-sheet'});
      expect(other.sheet.id, 'first');
      expect(other.selectedIds, isEmpty);
      expect(other.project, same(otherBefore));
      await _finish(tester);
    },
  );

  testWidgets('properties promote a function and focus a linked occurrence', (
    tester,
  ) async {
    final app = EditorController(
      initialProject: _project(),
      persistence: _MemoryPersistence(),
    );
    await _mount(tester, app);
    app.setSheet('second');
    app.select({'other-sheet'});
    app.setPanel(SidePanel.properties);
    await tester.pumpAndSettle();
    expect(find.text('Vedlejší funkce'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('set-main-function')));
    await tester.pumpAndSettle();
    expect(app.resolver.mainOccurrence('supply')!.device.id, 'other-sheet');
    expect(find.text('Hlavní funkce'), findsOneWidget);
    app.undo();
    await tester.pumpAndSettle();
    expect(app.resolver.mainOccurrence('supply')!.device.id, 'source');
    final link = find.textContaining('Hlavní funkce:');
    await tester.ensureVisible(link);
    await tester.tap(link);
    await tester.pumpAndSettle();
    expect(app.sheet.id, 'first');
    expect(app.selectedIds, {'source'});
    expect(app.viewport.deviceFocus, const Vec2(1000, 750));
    await _finish(tester);
  });

  testWidgets(
    'middle double click fits and centers the current sheet without changing selection',
    (tester) async {
      final app = EditorController(
        initialProject: _project(),
        persistence: _MemoryPersistence(),
      );
      await _mount(tester, app);
      app.select({'source'});
      await tester.pump();
      final before = app.project;
      final mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
        buttons: kMiddleMouseButton,
      );
      final point = _point(tester, app, const Vec2(1200, 800));
      await _middleClick(mouse, point, 100);
      await _middleClick(mouse, point, 230);
      await tester.pump();
      expect(app.viewport.zoom, lessThan(1));
      expect(
        app.viewport.worldViewport!.center.dx,
        closeTo(app.sheet.width / 2, .001),
      );
      expect(
        app.viewport.worldViewport!.center.dy,
        closeTo(app.sheet.height / 2, .001),
      );
      expect(app.selectedIds, {'source'});
      expect(app.project, same(before));
      await mouse.removePointer();
      await _finish(tester);
    },
  );

  testWidgets(
    'middle drag pans and cannot become the first click of a double click',
    (tester) async {
      final app = EditorController(
        initialProject: _project(),
        persistence: _MemoryPersistence(),
      );
      await _mount(tester, app);
      final viewport = app.viewport.worldViewport!;
      final mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
        buttons: kMiddleMouseButton,
      );
      final point = _point(tester, app, const Vec2(1200, 800));
      await mouse.down(point, timeStamp: const Duration(milliseconds: 100));
      await mouse.moveTo(
        point + const Offset(45, 20),
        timeStamp: const Duration(milliseconds: 130),
      );
      await mouse.up(timeStamp: const Duration(milliseconds: 150));
      await _middleClick(mouse, point + const Offset(45, 20), 230);
      await tester.pump();
      expect(app.viewport.zoom, 1);
      expect(
        app.viewport.worldViewport!.center,
        viewport.center - const Offset(45, 20),
      );
      await mouse.removePointer();
      await _finish(tester);
    },
  );

  testWidgets('middle double click resets the mounting view', (tester) async {
    final app = EditorController(
      initialProject: DemoProject.create(),
      persistence: _MemoryPersistence(),
    );
    await _mount(tester, app);
    app.setSheet(
      app.project.pages.firstWhere((s) => s.mountingView != null).id,
    );
    await tester.pumpAndSettle();
    final transformation =
        tester
            .widget<InteractiveViewer>(find.byType(InteractiveViewer))
            .transformationController!;
    transformation.value =
        Matrix4.identity()
          ..scaleByDouble(2, 2, 1, 1)
          ..translateByDouble(-70, -50, 0, 1);
    await tester.pump();
    final point = tester.getCenter(find.byType(InteractiveViewer));
    final mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      buttons: kMiddleMouseButton,
    );
    await _middleClick(mouse, point, 100);
    await _middleClick(mouse, point, 230);
    await tester.pump();
    expect(transformation.value, Matrix4.identity());
    expect(app.canUndo, isFalse);
    await mouse.removePointer();
    await _finish(tester);
  });
}
