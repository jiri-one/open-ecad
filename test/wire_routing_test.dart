// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/app/controller.dart';
import 'package:open_ecad/editor/schematic_canvas.dart';
import 'package:open_ecad/services/ecad_services.dart';

const _palette = CanvasPalette(
  background: Colors.white,
  paper: Colors.white,
  ink: Colors.black,
  muted: Colors.black,
  grid: Colors.black,
  selection: Colors.black,
  wire: Colors.black,
  sheetBorder: Colors.black,
  highContrast: true,
);

// Invented layout: a motor protective-earth terminal wired by hand to a
// terminal above it, with a route that first runs right, past the motor.
final _sheet = Sheet(
  id: 'sheet',
  name: 'Routing',
  number: '01',
  devices: const [
    Device(
      id: 'm',
      kind: DeviceKind.motor,
      designation: '-M7',
      position: Vec2(300, 400),
    ),
    Device(
      id: 'x',
      kind: DeviceKind.terminal,
      designation: '-X7',
      position: Vec2(520, 300),
    ),
  ],
  wires: [
    Wire(
      id: 'w',
      from: const TerminalRef(deviceId: 'm', portId: 'pe'),
      to: const TerminalRef(deviceId: 'x', portId: 'in'),
      waypoints: const [Vec2(450, 400), Vec2(450, 260), Vec2(520, 260)],
    ),
  ],
);

EcadProject _project() =>
    EcadProject(id: 'routing', name: 'Routing', pages: [_sheet]);

Map<String, Device> _devices(Sheet sheet) => {
  for (final device in sheet.devices) device.id: device,
};

class _MemoryPersistence extends ProjectPersistence {
  @override
  Future<void> saveAutosave(
    EcadProject project, {
    int? savedRevision,
    String? fileName,
  }) async {}
}

/// Painted unselected wires, as recorded from the canvas painter.
List<Path> _paintedWires(WidgetTester tester) {
  final paths = <Path>[];
  expect(
    find.descendant(
      of: find.byType(SchematicCanvas),
      matching: find.byType(CustomPaint),
    ),
    paints..everything((method, arguments) {
      if (method == #drawPath) {
        final paint = arguments[1] as Paint;
        // Paint stores widths as 32-bit floats.
        if (paint.style == PaintingStyle.stroke &&
            (paint.strokeWidth - 1.35).abs() < 1e-3) {
          paths.add(arguments[0] as Path);
        }
      }
      return true;
    }),
  );
  return paths;
}

/// The painted path has exactly the vertices of [route], in order.
void _expectPainted(Path path, List<Vec2> route) {
  final metrics = path.computeMetrics().toList();
  expect(metrics, hasLength(1));
  var distance = 0.0;
  for (var i = 0; i < route.length; i++) {
    if (i > 0) distance += route[i].distanceTo(route[i - 1]);
    final point = metrics.single.getTangentForOffset(distance)!.position;
    expect(point.dx, moreOrLessEquals(route[i].x, epsilon: 1e-3));
    expect(point.dy, moreOrLessEquals(route[i].y, epsilon: 1e-3));
  }
  expect(metrics.single.length, moreOrLessEquals(distance, epsilon: 1e-3));
}

void _expectClearOfBodies(List<Vec2> route, Wire wire, Sheet sheet) {
  final devices = _devices(sheet);
  final start = WireRouter.terminal(devices['m']!, wire.from.portId)!;
  final end = WireRouter.terminal(devices['x']!, wire.to.portId)!;
  expect(route.first, start.point);
  expect(route.last, end.point);
  final first = route[1] - route[0];
  expect(first.x / first.length, moreOrLessEquals(start.direction.x));
  expect(first.y / first.length, moreOrLessEquals(start.direction.y));
  for (var i = 1; i < route.length; i++) {
    expect(start.body!.crosses(route[i - 1], route[i]), isFalse);
    expect(end.body!.crosses(route[i - 1], route[i]), isFalse);
  }
}

void main() {
  testWidgets('drag preview draws exactly the route the move commits', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1100, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final engine = ProjectEngine(_project());
    final controller = SchematicViewportController();
    var selection = <String>{};
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder:
              (context, setState) => SchematicCanvas(
                sheet: engine.project.pages.single,
                selectedIds: selection,
                mode: CanvasMode.select,
                showGrid: true,
                palette: _palette,
                controller: controller,
                onSelectionChanged: (ids) => setState(() => selection = ids),
                onMoveDevices:
                    (positions) => setState(
                      () => engine.execute([MoveDevices('sheet', positions)]),
                    ),
                onPlaceDevice: (_, _) {},
                onConnect: (_, _) {},
                onDeleteWire: (_) {},
              ),
        ),
      ),
    );
    controller.reset();
    await tester.pump();
    _expectPainted(
      _paintedWires(tester).single,
      WireRouter.path(_sheet.wires.single, _devices(_sheet)),
    );

    // Drag the motor to the right, past the first bend of its manual route.
    final pointer = await tester.startGesture(const Offset(300, 400));
    await tester.pump();
    await pointer.moveTo(const Offset(600, 400));
    await tester.pump();
    final preview = _paintedWires(tester).single;
    expect(engine.project.revision, 0);
    expect(preview.getBounds().left, greaterThanOrEqualTo(520));

    await pointer.up();
    await tester.pump();
    final sheet = engine.project.pages.single;
    expect(sheet.deviceById('m')!.position, const Vec2(600, 400));
    final committed = WireRouter.path(sheet.wires.single, _devices(sheet));
    expect(committed, const [
      Vec2(633, 400),
      Vec2(650, 400),
      Vec2(650, 260),
      Vec2(520, 260),
      Vec2(520, 284),
    ]);
    _expectPainted(preview, committed);
    _expectPainted(_paintedWires(tester).single, committed);
    expect(tester.takeException(), isNull);
  });

  test('SVG export draws the committed route of a moved device', () {
    final engine = ProjectEngine(_project());
    engine.execute([
      MoveDevices('sheet', {'m': const Vec2(600, 400)}),
    ]);
    final svg = ProjectExportService().svg(engine.project);
    expect(
      svg,
      contains('<polyline points="633,400 650,400 650,260 520,260 520,284" '),
    );
    expect(svg, isNot(contains('450,400')));
  });

  test(
    'property moves and rotation keep the wire attached and are undoable',
    () {
      final app = EditorController(
        initialProject: _project(),
        persistence: _MemoryPersistence(),
      );
      addTearDown(app.dispose);
      final original = app.sheet.wires.single.toJson();
      final motor = app.sheet.deviceById('m')!;
      app.select({'m'});
      app.updateDevice(motor.copyWith(position: const Vec2(600, 400)));
      final moved = app.sheet.wires.single;
      _expectClearOfBodies(
        WireRouter.path(moved, _devices(app.sheet)),
        moved,
        app.sheet,
      );
      app.undo();
      expect(app.sheet.wires.single.toJson(), original);

      for (var turn = 1; turn <= 4; turn++) {
        app.rotateSelection();
        final wire = app.sheet.wires.single;
        _expectClearOfBodies(
          WireRouter.path(wire, _devices(app.sheet)),
          wire,
          app.sheet,
        );
      }
      for (var turn = 1; turn <= 4; turn++) {
        app.undo();
      }
      expect(app.sheet.wires.single.toJson(), original);
    },
  );
}
