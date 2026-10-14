import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/editor/schematic_canvas.dart';

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

final _sheet = Sheet(
  id: 'test',
  name: 'Interaction test',
  number: '01',
  devices: const [
    Device(
      id: 'q1',
      kind: DeviceKind.breaker,
      designation: '-Q1',
      position: Vec2(400, 300),
    ),
    Device(
      id: 'k1',
      kind: DeviceKind.contactor,
      designation: '-K1',
      position: Vec2(400, 450),
    ),
  ],
);

Future<void> _mount(
  WidgetTester tester, {
  required SchematicViewportController controller,
  CanvasMode mode = CanvasMode.select,
  DeviceKind? placingKind,
  bool readOnly = false,
  bool showGrid = true,
  Sheet? sheet,
  ValueChanged<Set<String>>? selectionChanged,
  ValueChanged<Map<String, Vec2>>? moved,
  void Function(DeviceKind, Vec2)? placed,
  void Function(TerminalRef, TerminalRef)? connected,
  ValueChanged<String>? deleted,
  SelectionMoveCallback? movedSelection,
  ValueChanged<DrawingElement>? graphicCreated,
}) async {
  tester.view.physicalSize = const Size(1100, 780);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  Set<String> selection = {};
  await tester.pumpWidget(
    MaterialApp(
      home: StatefulBuilder(
        builder: (context, setState) {
          return SchematicCanvas(
            sheet: sheet ?? _sheet,
            selectedIds: selection,
            mode: mode,
            readOnly: readOnly,
            placingKind: placingKind,
            showGrid: showGrid,
            palette: _palette,
            controller: controller,
            onSelectionChanged: (ids) {
              selectionChanged?.call(ids);
              setState(() => selection = ids);
            },
            onMoveDevices: moved ?? (_) {},
            onMoveSelection: movedSelection,
            onCreateGraphic: graphicCreated,
            onPlaceDevice: placed ?? (_, _) {},
            onConnect: connected ?? (_, _) {},
            onDeleteWire: deleted ?? (_) {},
          );
        },
      ),
    ),
  );
  controller.reset();
  await tester.pump();
}

void main() {
  testWidgets('drag selects a component and commits one snapped move', (
    tester,
  ) async {
    final controller = SchematicViewportController();
    final commits = <Map<String, Vec2>>[];
    Set<String>? selected;
    await _mount(
      tester,
      controller: controller,
      selectionChanged: (ids) => selected = ids,
      moved: commits.add,
    );
    final pointer = await tester.startGesture(const Offset(400, 300));
    await tester.pump();
    await pointer.moveTo(const Offset(452, 322));
    await tester.pump();
    await pointer.moveTo(const Offset(503, 347));
    await tester.pump();
    expect(commits, isEmpty);
    await pointer.up();
    await tester.pump();
    expect(selected, {'q1'});
    expect(commits, [
      {'q1': const Vec2(500, 350)},
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('wire tool connects exact terminals and Escape cancels a start', (
    tester,
  ) async {
    final pairs = <(TerminalRef, TerminalRef)>[];
    await _mount(
      tester,
      controller: SchematicViewportController(),
      mode: CanvasMode.wire,
      connected: (a, b) => pairs.add((a, b)),
    );
    await tester.tapAt(const Offset(400, 332));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.tapAt(const Offset(400, 418));
    expect(pairs, isEmpty);
    await tester.tapAt(const Offset(400, 332));
    expect(pairs, [
      (
        const TerminalRef(deviceId: 'k1', portId: 'in'),
        const TerminalRef(deviceId: 'q1', portId: 'out'),
      ),
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('placement snaps, and read-only does not move a selection', (
    tester,
  ) async {
    final placements = <Vec2>[];
    await _mount(
      tester,
      controller: SchematicViewportController(),
      mode: CanvasMode.place,
      placingKind: DeviceKind.lamp,
      placed: (_, point) => placements.add(point),
    );
    await tester.tapAt(const Offset(553, 273));
    expect(placements, [const Vec2(550, 270)]);
    final moves = <Map<String, Vec2>>[];
    await _mount(
      tester,
      controller: SchematicViewportController(),
      readOnly: true,
      moved: moves.add,
    );
    await tester.dragFrom(const Offset(400, 300), const Offset(120, 80));
    expect(moves, isEmpty);
  });

  testWidgets(
    'marquee selects only intersecting bodies and zoom stays anchored',
    (tester) async {
      final controller = SchematicViewportController();
      Set<String>? selected;
      await _mount(
        tester,
        controller: controller,
        selectionChanged: (ids) => selected = ids,
      );
      await tester.dragFrom(const Offset(370, 255), const Offset(60, 240));
      await tester.pump();
      expect(selected, {'q1', 'k1'});
      await tester.sendEventToBinding(
        const PointerScrollEvent(
          position: Offset(400, 300),
          scrollDelta: Offset(0, -100),
        ),
      );
      await tester.pump();
      expect(controller.zoom, greaterThan(1));
      await tester.tapAt(const Offset(100, 100));
      await tester.pump();
      await tester.tapAt(const Offset(400, 300));
      await tester.pump();
      expect(selected, {'q1'});
    },
  );

  testWidgets('offscreen objects are culled and wires can be deleted', (
    tester,
  ) async {
    final controller = SchematicViewportController();
    String? deleted;
    final sheet = _sheet.copyWith(
      devices: [
        ..._sheet.devices,
        const Device(
          id: 'far',
          kind: DeviceKind.lamp,
          designation: '-H1',
          position: Vec2(5000, 5000),
        ),
      ],
      wires: [
        Wire(
          id: 'wire',
          from: const TerminalRef(deviceId: 'q1', portId: 'out'),
          to: const TerminalRef(deviceId: 'k1', portId: 'in'),
        ),
      ],
    );
    await _mount(
      tester,
      controller: controller,
      sheet: sheet,
      deleted: (id) => deleted = id,
    );
    expect(controller.totalPrimitiveCount, 4);
    expect(controller.visiblePrimitiveCount, 3);
    await tester.tapAt(const Offset(400, 375));
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    expect(deleted, 'wire');
  });

  testWidgets(
    'imported graphics use precise hits, topmost order and atomic mixed moves',
    (tester) async {
      final graphics = [
        DrawingElement(
          id: 'frame',
          kind: DrawingKind.path,
          position: const Vec2(40, 40),
          width: 1000,
          height: 680,
          stroke: '#000000',
          path: [
            PathSegment(verb: PathVerb.moveTo, points: [const Vec2(0, 0)]),
            PathSegment(verb: PathVerb.lineTo, points: [const Vec2(1000, 0)]),
            PathSegment(verb: PathVerb.lineTo, points: [const Vec2(1000, 680)]),
            PathSegment(verb: PathVerb.lineTo, points: [const Vec2(0, 680)]),
            PathSegment(verb: PathVerb.close),
          ],
        ),
        DrawingElement(
          id: 'under',
          kind: DrawingKind.text,
          position: const Vec2(550, 300),
          width: 100,
          height: 20,
          text: 'Under',
        ),
        DrawingElement(
          id: 'text',
          kind: DrawingKind.text,
          position: const Vec2(550, 300),
          width: 100,
          height: 20,
          text: 'Text',
        ),
      ];
      Set<String> selection = {};
      final commits = <(Map<String, Vec2>, Map<String, Vec2>)>[];
      await _mount(
        tester,
        controller: SchematicViewportController(),
        sheet: _sheet.copyWith(showFrame: false, graphics: graphics),
        showGrid: false,
        selectionChanged: (ids) => selection = ids,
        movedSelection: ({required devices, required graphics}) {
          commits.add((devices, graphics));
        },
      );
      await tester.tapAt(const Offset(600, 310));
      await tester.pump();
      expect(selection, {'text'});
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.tapAt(const Offset(400, 300));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(selection, {'q1', 'text'});
      final pointer = await tester.startGesture(const Offset(600, 310));
      await pointer.moveBy(const Offset(23, 17));
      await tester.pump();
      expect(commits, isEmpty);
      await pointer.up();
      expect(commits, hasLength(1));
      expect(commits.single.$1, {'q1': const Vec2(423, 317)});
      expect(commits.single.$2, {'text': const Vec2(573, 317)});
      await tester.tapAt(const Offset(800, 400));
      expect(
        selection,
        isEmpty,
        reason: 'The empty frame interior is not a stroke.',
      );
      await tester.dragFrom(const Offset(540, 290), const Offset(120, 40));
      expect(selection, {
        'under',
        'text',
      }, reason: 'Marquee must not select an enclosing page frame.');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'drawing tools create native shapes and text, cancel and respect read-only',
    (tester) async {
      final created = <DrawingElement>[];
      await _mount(
        tester,
        controller: SchematicViewportController(),
        mode: CanvasMode.drawRectangle,
        graphicCreated: created.add,
      );
      await tester.dragFrom(const Offset(703, 503), const Offset(-103, -82));
      expect(created, hasLength(1));
      expect(created.single.position, const Vec2(600, 420));
      expect(created.single.width, 100);
      expect(created.single.height, 80);
      expect(created.single.path.last.verb, PathVerb.close);
      final pointer = await tester.startGesture(const Offset(600, 200));
      await pointer.moveBy(const Offset(100, 100));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await pointer.up();
      expect(created, hasLength(1));
      await _mount(
        tester,
        controller: SchematicViewportController(),
        mode: CanvasMode.drawLine,
        showGrid: false,
        graphicCreated: created.add,
      );
      await tester.dragFrom(const Offset(701, 401), const Offset(-90, 32));
      expect(created.last.path.last.points.single, const Vec2(0, 32));
      await _mount(
        tester,
        controller: SchematicViewportController(),
        mode: CanvasMode.drawText,
        graphicCreated: created.add,
      );
      await tester.tapAt(const Offset(601, 201));
      expect(created.last.kind, DrawingKind.text);
      expect(created.last.position, const Vec2(600, 200));
      await _mount(
        tester,
        controller: SchematicViewportController(),
        mode: CanvasMode.drawText,
        readOnly: true,
        graphicCreated: created.add,
      );
      await tester.tapAt(const Offset(601, 201));
      expect(created, hasLength(3));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('fit uses imported page dimensions and culls graphics', (
    tester,
  ) async {
    final controller = SchematicViewportController();
    final sheet = Sheet(
      id: 'large',
      name: 'Large PDF',
      number: '1',
      width: 2200,
      height: 1560,
      showFrame: false,
      graphics: [
        DrawingElement(
          id: 'near',
          kind: DrawingKind.text,
          position: const Vec2(1000, 700),
          width: 100,
          height: 20,
          text: 'Near',
        ),
        DrawingElement(
          id: 'far',
          kind: DrawingKind.text,
          position: const Vec2(9000, 7000),
          width: 100,
          height: 20,
          text: 'Far',
        ),
      ],
    );
    await _mount(tester, controller: controller, sheet: sheet);
    controller.fit();
    await tester.pump();
    expect(controller.zoom, closeTo(720 / 1560, .0001));
    expect(controller.totalPrimitiveCount, 2);
    expect(controller.visiblePrimitiveCount, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'read-only preview blocks edits but preserves selection, pan and zoom',
    (tester) async {
      final mutations = <String>[];
      Set<String> selected = {};
      final sheet = _sheet.copyWith(
        wires: [
          Wire(
            id: 'wire',
            from: const TerminalRef(deviceId: 'q1', portId: 'out'),
            to: const TerminalRef(deviceId: 'k1', portId: 'in'),
          ),
        ],
      );
      final original = sheet.toJson();
      final viewport = SchematicViewportController();
      await _mount(
        tester,
        controller: viewport,
        readOnly: true,
        sheet: sheet,
        selectionChanged: (ids) => selected = ids,
        moved: (_) => mutations.add('move'),
        placed: (_, _) => mutations.add('place'),
        connected: (_, _) => mutations.add('connect'),
        deleted: (_) => mutations.add('delete'),
      );

      await tester.tapAt(const Offset(400, 300));
      await tester.pump();
      expect(selected, {'q1'});
      await tester.dragFrom(const Offset(400, 300), const Offset(120, 80));
      await tester.pump();
      await tester.tapAt(const Offset(400, 375));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      expect(mutations, isEmpty);

      // Space-pan changes only the viewport. The device must become clickable
      // at its translated screen location while keeping its document position.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
      await tester.dragFrom(const Offset(100, 100), const Offset(100, 60));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
      await tester.pump();
      await tester.tapAt(const Offset(500, 360));
      await tester.pump();
      expect(selected, {'q1'});
      expect(sheet.deviceById('q1')!.position, const Vec2(400, 300));

      // A zoom anchored on the component leaves that same screen point usable.
      await tester.sendEventToBinding(
        const PointerScrollEvent(
          position: Offset(500, 360),
          scrollDelta: Offset(0, -100),
        ),
      );
      await tester.pump();
      expect(viewport.zoom, greaterThan(1));
      await tester.tapAt(const Offset(50, 700));
      await tester.pump();
      await tester.tapAt(const Offset(500, 360));
      await tester.pump();
      expect(selected, {'q1'});

      // readOnly remains authoritative even when an editing tool is supplied.
      await _mount(
        tester,
        controller: SchematicViewportController(),
        readOnly: true,
        sheet: sheet,
        mode: CanvasMode.place,
        placingKind: DeviceKind.lamp,
        moved: (_) => mutations.add('move'),
        placed: (_, _) => mutations.add('place'),
        connected: (_, _) => mutations.add('connect'),
        deleted: (_) => mutations.add('delete'),
      );
      await tester.tapAt(const Offset(550, 270));
      await tester.pump();
      await _mount(
        tester,
        controller: SchematicViewportController(),
        readOnly: true,
        sheet: sheet,
        mode: CanvasMode.wire,
        moved: (_) => mutations.add('move'),
        placed: (_, _) => mutations.add('place'),
        connected: (_, _) => mutations.add('connect'),
        deleted: (_) => mutations.add('delete'),
      );
      await tester.tapAt(const Offset(400, 332));
      await tester.pump();
      await tester.tapAt(const Offset(400, 418));
      await tester.pump();
      await tester.tapAt(const Offset(400, 375));
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);

      expect(mutations, isEmpty);
      expect(sheet.toJson(), original);
      expect(tester.takeException(), isNull);
    },
  );
}
