import 'dart:math' as math;

import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/app/controller.dart';
import 'package:open_ecad/app/theme.dart';
import 'package:open_ecad/editor/mounting_canvas.dart';
import 'package:open_ecad/editor/schematic_canvas.dart';
import 'package:open_ecad/services/project_persistence.dart';
import 'package:open_ecad/widgets/report_view.dart';

enum _Canvas { schematic, mounting, report }

class _MemoryPersistence extends ProjectPersistence {
  @override
  Future<void> saveWorkingCopy(WorkingCopy copy) async {}
}

class _Harness {
  _Harness(this.kind, this.app, this.availableSize, this.pageSize);

  final _Canvas kind;
  final EditorController app;
  final ValueNotifier<Size> availableSize;
  final Size pageSize;

  Finder get viewport => find.byType(
    kind == _Canvas.schematic ? SchematicCanvas : InteractiveViewer,
  );

  RenderBox surface(WidgetTester tester) => tester.renderObject<RenderBox>(
    find.byKey(ValueKey('${kind.name}-surface')),
  );

  Rect pageRect(WidgetTester tester) {
    if (kind == _Canvas.schematic) {
      final origin = tester.getTopLeft(viewport);
      return Rect.fromPoints(
        origin + app.viewport.worldToLocal(Vec2.zero)!,
        origin +
            app.viewport.worldToLocal(Vec2(pageSize.width, pageSize.height))!,
      );
    }
    final box = surface(tester);
    return Rect.fromPoints(
      box.localToGlobal(Offset.zero),
      box.localToGlobal(box.size.bottomRight(Offset.zero)),
    );
  }

  Offset worldCenter(WidgetTester tester) {
    if (kind == _Canvas.schematic) return app.viewport.worldViewport!.center;
    final box = surface(tester);
    final center = box.globalToLocal(tester.getCenter(viewport));
    return Offset(
      center.dx * pageSize.width / box.size.width,
      center.dy * pageSize.height / box.size.height,
    );
  }

  void expectFitted(WidgetTester tester) {
    final paper = pageRect(tester);
    final view = tester.getRect(viewport);
    final left = paper.left - view.left;
    final top = paper.top - view.top;
    expect(left, greaterThanOrEqualTo(8 - 1e-6));
    expect(top, greaterThanOrEqualTo(8 - 1e-6));
    expect(view.right - paper.right, closeTo(left, 1e-6));
    expect(view.bottom - paper.bottom, closeTo(top, 1e-6));
    expect(math.min(left, top), closeTo(8, 1e-6));
    expect(
      paper.width / paper.height,
      closeTo(pageSize.width / pageSize.height, 1e-6),
    );
    expect(tester.takeException(), isNull);
  }

  Future<void> pan(WidgetTester tester) async {
    final pointer = await tester.startGesture(
      tester.getCenter(viewport),
      kind: PointerDeviceKind.mouse,
      buttons: kind == _Canvas.schematic ? kMiddleMouseButton : kPrimaryButton,
    );
    await pointer.moveBy(const Offset(50, 35));
    await tester.pump(const Duration(milliseconds: 200));
    await pointer.moveBy(const Offset(40, 25));
    await tester.pump(const Duration(milliseconds: 200));
    await pointer.up();
    await tester.pumpAndSettle();
  }
}

Future<_Harness> _mount(
  WidgetTester tester,
  _Canvas kind, {
  Size pageSize = const Size(1100, 780),
}) async {
  tester.view.physicalSize = const Size(1200, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final app = EditorController(
    persistence: _MemoryPersistence(),
    initialProject: EcadProject(
      id: 'fit',
      name: 'Canvas fit',
      mountingLayouts: [
        MountingLayout(
          id: 'layout',
          name: 'Panel',
          widthMm: 300,
          heightMm: 200,
        ),
      ],
      pages: [
        Sheet(
          id: 'sheet',
          name: 'Sheet',
          number: '1',
          type: switch (kind) {
            _Canvas.schematic => SheetType.multiLine,
            _Canvas.mounting => SheetType.cabinetLayout,
            _Canvas.report => SheetType.billOfMaterials,
          },
          width: pageSize.width,
          height: pageSize.height,
          paperSizeMm:
              pageSize.width > 10000 || pageSize.width < 180
                  ? SizeMm(
                    width: 400,
                    height: 400 * pageSize.height / pageSize.width,
                  )
                  : SizeMm(width: pageSize.width, height: pageSize.height),
          mountingView:
              kind == _Canvas.mounting
                  ? const MountingView(
                    layoutId: 'layout',
                    viewport: RectUnits(x: 0, y: 0, width: 300, height: 200),
                  )
                  : null,
          report:
              kind == _Canvas.report
                  ? const BomTableSpec(kind: BomReportKind.articles)
                  : null,
        ),
      ],
    ),
  );
  final availableSize = ValueNotifier(const Size(1000, 700));
  addTearDown(app.dispose);
  addTearDown(availableSize.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: ValueListenableBuilder(
            valueListenable: availableSize,
            builder:
                (context, size, _) => SizedBox(
                  width: size.width,
                  height: size.height,
                  child: switch (kind) {
                    _Canvas.schematic => SchematicCanvas(
                      sheet: app.sheet,
                      project: app.project,
                      selectedIds: const {},
                      mode: CanvasMode.select,
                      showGrid: false,
                      palette:
                          EcadColors.forAppearance(
                            EcadAppearance.paper,
                          ).canvasPalette,
                      controller: app.viewport,
                      onSelectionChanged: (_) {},
                      onMoveDevices: (_) {},
                      onPlaceDevice: (_, _) {},
                      onConnect: (_, _) {},
                      onDeleteWire: (_) {},
                    ),
                    _Canvas.mounting => MountingCanvas(app: app),
                    _Canvas.report => ReportView(app: app),
                  },
                ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _Harness(kind, app, availableSize, pageSize);
}

void main() {
  for (final kind in _Canvas.values) {
    for (final jitterOnFirstClick in [false, true]) {
      testWidgets(
        '${kind.name} double middle click stays centered after inertia from the ${jitterOnFirstClick ? 'first' : 'second'} click',
        (tester) async {
          final harness = await _mount(tester, kind);
          harness.app.viewport.zoomIn();
          await tester.pumpAndSettle();
          final point = tester.getCenter(harness.viewport);
          final mouse = await tester.createGesture(
            kind: PointerDeviceKind.mouse,
            buttons: kMiddleMouseButton,
          );
          Future<void> click(int time, {required bool jitter}) async {
            await mouse.down(point, timeStamp: Duration(milliseconds: time));
            if (jitter) {
              for (var step = 1; step <= 5; step++) {
                await mouse.moveTo(
                  point + Offset(step * 2, step * 2),
                  timeStamp: Duration(milliseconds: time + step * 4),
                );
                await tester.pump(const Duration(milliseconds: 4));
              }
            }
            await mouse.up(timeStamp: Duration(milliseconds: time + 30));
          }

          await click(100, jitter: jitterOnFirstClick);
          await tester.pump(const Duration(milliseconds: 100));
          await click(230, jitter: !jitterOnFirstClick);
          await tester.pumpAndSettle();
          harness.expectFitted(tester);
          await mouse.removePointer();
        },
      );
    }

    testWidgets('${kind.name} viewport resize cancels a pending middle click', (
      tester,
    ) async {
      final harness = await _mount(tester, kind);
      harness.app.viewport.zoomIn();
      await tester.pumpAndSettle();
      final width = harness.pageRect(tester).width;
      final point = tester.getCenter(harness.viewport);
      final mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
        buttons: kMiddleMouseButton,
      );
      await mouse.down(point, timeStamp: const Duration(milliseconds: 100));
      await mouse.up(timeStamp: const Duration(milliseconds: 130));
      harness.availableSize.value = const Size(900, 650);
      await tester.pumpAndSettle();
      await mouse.down(point, timeStamp: const Duration(milliseconds: 230));
      await mouse.up(timeStamp: const Duration(milliseconds: 260));
      await tester.pumpAndSettle();
      expect(harness.pageRect(tester).width, closeTo(width, 1e-6));
      expect(tester.takeException(), isNull);
      await mouse.removePointer();
    });

    for (final direction in [-1, 1]) {
      testWidgets(
        '${kind.name} middle double click fits after wheel ${direction < 0 ? 'up' : 'down'}, including the viewport gutter',
        (tester) async {
          final harness = await _mount(tester, kind);
          final original = harness.app.project;
          harness.app.viewport.zoomOut();
          await tester.pumpAndSettle();
          await tester.sendEventToBinding(
            PointerScrollEvent(
              kind: PointerDeviceKind.mouse,
              position: tester.getCenter(harness.viewport),
              scrollDelta: Offset(0, direction * 40),
            ),
          );
          await tester.pumpAndSettle();
          await harness.pan(tester);
          final point =
              tester.getTopLeft(harness.viewport) + const Offset(3, 3);
          expect(harness.pageRect(tester).contains(point), isFalse);
          final mouse = await tester.createGesture(
            kind: PointerDeviceKind.mouse,
            buttons: kMiddleMouseButton,
          );
          await mouse.down(
            point,
            timeStamp: const Duration(milliseconds: 1000),
          );
          await mouse.moveTo(
            point + const Offset(6, 2),
            timeStamp: const Duration(milliseconds: 1020),
          );
          await mouse.up(timeStamp: const Duration(milliseconds: 1040));
          await mouse.down(
            point + const Offset(6, 2),
            timeStamp: const Duration(milliseconds: 1130),
          );
          await mouse.moveTo(
            point + const Offset(10, 3),
            timeStamp: const Duration(milliseconds: 1150),
          );
          await mouse.up(timeStamp: const Duration(milliseconds: 1170));
          await tester.pumpAndSettle();
          harness.expectFitted(tester);
          expect(harness.app.project, same(original));
          expect(harness.app.canUndo, isFalse);
          await mouse.removePointer();
        },
      );
    }

    testWidgets('${kind.name} middle drag followed by one click does not fit', (
      tester,
    ) async {
      final harness = await _mount(tester, kind);
      harness.app.viewport.zoomIn();
      await tester.pumpAndSettle();
      final width = harness.pageRect(tester).width;
      final point = tester.getCenter(harness.viewport);
      final mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
        buttons: kMiddleMouseButton,
      );
      await mouse.down(point, timeStamp: const Duration(milliseconds: 100));
      await mouse.moveBy(
        const Offset(45, 20),
        timeStamp: const Duration(milliseconds: 130),
      );
      await mouse.up(timeStamp: const Duration(milliseconds: 150));
      await mouse.down(
        point + const Offset(45, 20),
        timeStamp: const Duration(milliseconds: 230),
      );
      await mouse.up(timeStamp: const Duration(milliseconds: 260));
      await tester.pumpAndSettle();
      expect(harness.pageRect(tester).width, closeTo(width, 1e-6));
      expect(tester.takeException(), isNull);
      await mouse.removePointer();
    });

    for (final portrait in [false, true]) {
      testWidgets(
        '${kind.name} fits the whole ${portrait ? 'portrait' : 'landscape'} page with an 8 px gutter',
        (tester) async {
          final harness = await _mount(
            tester,
            kind,
            pageSize: portrait ? const Size(297, 420) : const Size(420, 297),
          );
          harness.expectFitted(tester);
          harness.availableSize.value = const Size(700, 900);
          await tester.pumpAndSettle();
          harness.expectFitted(tester);
          tester.view.physicalSize = const Size(650, 500);
          await tester.pumpAndSettle();
          harness.expectFitted(tester);
        },
      );
    }

    for (final zoom in [false, true]) {
      testWidgets(
        '${kind.name} preserves manual ${zoom ? 'zoom and pan' : 'pan'} on resize and resumes fitting on command',
        (tester) async {
          final harness = await _mount(tester, kind);
          if (zoom) {
            harness.app.viewport.zoomIn();
            await tester.pumpAndSettle();
          }
          final beforePan = harness.worldCenter(tester);
          await harness.pan(tester);
          final center = harness.worldCenter(tester);
          expect((center - beforePan).distance, greaterThan(10));
          final size = harness.pageRect(tester).size;
          for (final available in [
            const Size(700, 500),
            const Size(1100, 900),
          ]) {
            harness.availableSize.value = available;
            await tester.pumpAndSettle();
            final nextSize = harness.pageRect(tester).size;
            expect(nextSize.width, closeTo(size.width, 1e-6));
            expect(nextSize.height, closeTo(size.height, 1e-6));
            expect(
              (harness.worldCenter(tester) - center).distance,
              lessThan(1e-6),
            );
            expect(tester.takeException(), isNull);
          }
          harness.app.viewport.fit();
          await tester.pumpAndSettle();
          harness.expectFitted(tester);
          harness.availableSize.value = const Size(800, 600);
          await tester.pumpAndSettle();
          harness.expectFitted(tester);
        },
      );
    }
  }

  for (final kind in [_Canvas.schematic, _Canvas.mounting]) {
    for (final size in [const Size(40000, 30000), const Size(40, 30)]) {
      testWidgets(
        '${kind.name} fits ${size.width} x ${size.height} pages and zooms smoothly in both directions',
        (tester) async {
          final harness = await _mount(tester, kind, pageSize: size);
          harness.expectFitted(tester);
          final fitted = harness.pageRect(tester).width;
          harness.app.viewport.zoomIn();
          await tester.pumpAndSettle();
          expect(harness.pageRect(tester).width, closeTo(fitted * 1.2, 1e-6));
          harness.app.viewport.fit();
          await tester.pumpAndSettle();
          harness.app.viewport.zoomOut();
          await tester.pumpAndSettle();
          expect(harness.pageRect(tester).width, closeTo(fitted / 1.2, 1e-6));
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
