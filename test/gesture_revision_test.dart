import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/app/controller.dart';
import 'package:open_ecad/editor/mounting_canvas.dart';
import 'package:open_ecad/editor/schematic_canvas.dart';
import 'package:open_ecad/services/project_persistence.dart';

class _Persistence extends ProjectPersistence {
  @override
  Future<void> saveWorkingCopy(WorkingCopy copy) async {}
}

void main() {
  testWidgets('a document edit cancels a pending schematic drag', (
    tester,
  ) async {
    final seed = createBuiltinComponent(
      componentId: 'component',
      deviceId: 'device',
      kind: DeviceKind.breaker,
      designation: '-Q1',
      position: const Vec2(400, 300),
    );
    final app = EditorController(
      persistence: _Persistence(),
      initialProject: EcadProject(
        id: 'project',
        name: 'Synthetic',
        components: [seed.component],
        pages: [
          Sheet(
            id: 'sheet',
            name: 'Sheet',
            number: '1',
            devices: [seed.device],
          ),
        ],
      ),
    );
    addTearDown(app.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: ListenableBuilder(
          listenable: app,
          builder:
              (_, _) => SchematicCanvas(
                project: app.project,
                sheet: app.sheet,
                controller: app.viewport,
                documentIdentity: app,
                selectedIds: app.selectedIds,
                mode: CanvasMode.select,
                showGrid: true,
                palette: const CanvasPalette(
                  background: Colors.white,
                  paper: Colors.white,
                  ink: Colors.black,
                  muted: Colors.black,
                  grid: Colors.black,
                  selection: Colors.black,
                  wire: Colors.black,
                  sheetBorder: Colors.black,
                ),
                onSelectionChanged: app.select,
                onMoveDevices: app.moveDevices,
                onPlaceDevice: app.placeDevice,
                onConnect: app.connect,
                onDeleteWire: app.deleteWire,
              ),
        ),
      ),
    );
    await tester.pump();
    final at = app.viewport.worldToLocal(seed.device.position)!;
    final pointer = await tester.startGesture(
      at,
      kind: PointerDeviceKind.mouse,
    );
    await pointer.moveBy(const Offset(40, 30));
    await tester.pump();
    app.moveDevices({'device': const Vec2(600, 500)});
    await tester.pump();
    final revision = app.project.revision;
    await pointer.up();
    await tester.pump();
    expect(app.project.revision, revision);
    expect(app.sheet.devices.single.position, const Vec2(600, 500));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets('a document edit cancels a pending mounting drag', (
    tester,
  ) async {
    final app = EditorController(
      persistence: _Persistence(),
      initialProject: EcadProject(
        id: 'project',
        name: 'Synthetic',
        components: const [
          Component(
            id: 'component',
            designation: '-A1',
            mountingSizeOverrideMm: DimensionsMm(width: 40, height: 40),
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
                id: 'placement',
                componentId: 'component',
                centerMm: Vec2(60, 80),
              ),
            ],
          ),
        ],
        pages: [
          Sheet(
            id: 'sheet',
            name: 'Panel',
            number: '1',
            type: SheetType.cabinetLayout,
            mountingView: const MountingView(
              layoutId: 'layout',
              scaleDenominator: 2,
              viewport: RectUnits(x: 50, y: 50, width: 900, height: 500),
            ),
          ),
        ],
      ),
    );
    addTearDown(app.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: ListenableBuilder(
          listenable: app,
          builder: (_, _) => MountingCanvas(app: app, showControls: false),
        ),
      ),
    );
    await tester.pump();
    final surface = tester.renderObject<RenderBox>(
      find.byKey(const ValueKey('mounting-surface')),
    );
    final transform = MountingTransform(app.sheet, app.sheet.mountingView!);
    final at = transform.toSheet(app.activeLayout!.placements.single.centerMm);
    final point = surface.localToGlobal(
      Offset(at.x, at.y) * (surface.size.width / app.sheet.width),
    );
    final pointer = await tester.startGesture(
      point,
      kind: PointerDeviceKind.mouse,
    );
    await pointer.moveBy(const Offset(40, 30));
    await tester.pump();
    app.updatePlacement(
      app.activeLayout!.placements.single.copyWith(
        centerMm: const Vec2(180, 120),
        rotation: 90,
      ),
    );
    await tester.pump();
    final revision = app.project.revision;
    await pointer.up();
    await tester.pump();
    expect(app.project.revision, revision);
    expect(app.activeLayout!.placements.single.centerMm, const Vec2(180, 120));
    expect(app.activeLayout!.placements.single.rotation, 90);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 500));
  });
}
