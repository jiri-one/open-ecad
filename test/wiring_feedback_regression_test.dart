// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/app/controller.dart';
import 'package:open_ecad/editor/schematic_canvas.dart';
import 'package:open_ecad/services/project_persistence.dart';
import 'package:open_ecad/services/wire_route_description.dart';

import '../packages/ecad_core/test/support.dart';

class _MemoryPersistence extends ProjectPersistence {
  @override
  Future<String> saveWorkingCopy(
    WorkingCopy copy, {
    EncodedProject? encoded,
  }) async => 'memory';
}

Device _block(String id, Vec2 at, PortSide side) => Device(
  id: id,
  componentId: 'component_$id',
  functionId: 'function_$id',
  position: at,
  symbol: PortBlockSpec(
    width: 20,
    height: 20,
    ports: [
      BlockPort(id: 'p', terminalId: 'terminal_$id', side: side, fraction: .5),
    ],
  ),
);

class _CountedSheet extends Sheet {
  _CountedSheet()
    : super(
        id: 'hidden',
        name: 'Unshown',
        number: '2',
        devices: [
          _block('hidden_a', const Vec2(100, 100), PortSide.right),
          _block('hidden_b', const Vec2(300, 100), PortSide.left),
        ],
      );

  int reads = 0;

  @override
  List<Device> get devices {
    reads++;
    return super.devices;
  }
}

const _palette = CanvasPalette(
  background: Colors.white,
  paper: Colors.white,
  ink: Colors.black,
  muted: Colors.black,
  grid: Colors.grey,
  selection: Colors.blue,
  wire: Colors.black,
  sheetBorder: Colors.black,
);

void main() {
  testWidgets('group drag commits the same manual route as its preview', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1100, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final wire = Wire(
      id: 'wire',
      from: const TerminalRef(deviceId: 'a', portId: 'p'),
      to: const CornerRef(cornerId: 'corner', portId: 'a'),
      waypoints: const [
        Vec2(140, 100),
        Vec2(140, 170),
        Vec2(240, 170),
        Vec2(240, 200),
      ],
    );
    final project = syntheticProject(
      id: 'synthetic',
      name: 'Group movement',
      pages: [
        Sheet(
          id: 's',
          name: 'Group movement',
          number: '1',
          showFrame: false,
          devices: [_block('a', const Vec2(100, 100), PortSide.right)],
          corners: const [
            ConnectionCorner(id: 'corner', position: Vec2(200, 200)),
          ],
          wires: [wire],
        ),
      ],
    );
    final app = EditorController(
      initialProject: project,
      persistence: _MemoryPersistence(),
    );
    addTearDown(app.dispose);
    app.select({'a', 'corner'});
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(splashFactory: InkRipple.splashFactory),
        home: ListenableBuilder(
          listenable: app,
          builder:
              (context, _) => SchematicCanvas(
                project: app.project,
                sheet: app.sheet,
                documentIdentity: app,
                selectedIds: app.selectedIds,
                mode: app.mode,
                showGrid: false,
                palette: _palette,
                controller: app.viewport,
                onSelectionChanged: app.select,
                onMoveDevices: app.moveDevices,
                onMoveSelection: app.moveSelection,
                onPlaceDevice: app.placeDevice,
                onConnect: app.connect,
                onDeleteWire: app.deleteWire,
              ),
        ),
      ),
    );
    app.viewport.reset();
    await tester.pump();

    Rect routeBounds() {
      final paths = <Rect>[];
      expect(
        find
            .descendant(
              of: find.byType(SchematicCanvas),
              matching: find.byType(CustomPaint),
            )
            .first,
        paints..everything((method, args) {
          if (method == #drawPath &&
              ((args[1] as Paint).strokeWidth - 1.35).abs() < 1e-5) {
            paths.add((args[0] as Path).getBounds());
          }
          return true;
        }),
      );
      return paths.single;
    }

    final mouse = await tester.startGesture(
      const Offset(100, 100),
      kind: PointerDeviceKind.mouse,
    );
    await mouse.moveBy(const Offset(30, 20));
    await tester.pump();
    final preview = routeBounds();
    await mouse.up();
    await tester.pump();
    expect(routeBounds(), preview);
    const translated = [
      Vec2(170, 120),
      Vec2(170, 190),
      Vec2(270, 190),
      Vec2(270, 220),
    ];
    expect(app.sheet.wires.single.waypoints, translated);
    app.undo();
    expect(app.sheet.wires.single.waypoints, wire.waypoints);
    app.redo();
    expect(app.sheet.wires.single.waypoints, translated);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpWidget(const SizedBox());
  });

  test('two corners move their complete manual route in one history step', () {
    final wire = Wire(
      id: 'wire',
      from: const CornerRef(cornerId: 'one', portId: 'a'),
      to: const CornerRef(cornerId: 'two', portId: 'b'),
      waypoints: const [
        Vec2(260, 200),
        Vec2(260, 260),
        Vec2(330, 260),
        Vec2(330, 300),
      ],
    );
    final app = EditorController(
      initialProject: EcadProject(
        id: 'synthetic',
        name: 'Two corners',
        pages: [
          Sheet(
            id: 's',
            name: 'Two corners',
            number: '1',
            corners: const [
              ConnectionCorner(id: 'one', position: Vec2(200, 200)),
              ConnectionCorner(
                id: 'two',
                position: Vec2(400, 300),
                orientation: CornerOrientation.topRight,
              ),
            ],
            wires: [wire],
          ),
        ],
      ),
      persistence: _MemoryPersistence(),
    );
    addTearDown(app.dispose);
    app.moveSelection(
      devices: {},
      graphics: {},
      corners: {'one': const Vec2(230, 220), 'two': const Vec2(430, 320)},
    );
    expect(app.project.revision, 1);
    expect(app.sheet.wires.single.waypoints, [
      for (final point in wire.waypoints) point + const Vec2(30, 20),
    ]);
    app.undo();
    expect(app.sheet.wires.single.waypoints, wire.waypoints);
    app.redo();
    expect(app.sheet.wires.single.waypoints, [
      for (final point in wire.waypoints) point + const Vec2(30, 20),
    ]);
  });

  test('a device and continuation preserve their manual bends together', () {
    final wire = Wire(
      id: 'wire',
      from: const TerminalRef(deviceId: 'a', portId: 'p'),
      to: const ContinuationRef(markerId: 'marker'),
      waypoints: const [
        Vec2(140, 100),
        Vec2(140, 170),
        Vec2(240, 170),
        Vec2(240, 200),
      ],
    );
    final base = syntheticProject(
      id: 'synthetic',
      name: 'Continuation movement',
      pages: [
        Sheet(
          id: 's',
          name: 'Continuation movement',
          number: '1',
          devices: [_block('a', const Vec2(100, 100), PortSide.right)],
          continuations: const [
            ContinuationMarker(
              id: 'marker',
              linkId: 'link',
              position: Vec2(300, 200),
            ),
          ],
          wires: [wire],
        ),
      ],
    );
    final app = EditorController(
      initialProject: base.copyWith(
        continuationLinks: const [ContinuationLink(id: 'link', label: 'Link')],
      ),
      persistence: _MemoryPersistence(),
    );
    addTearDown(app.dispose);
    app.moveSelection(
      devices: {'a': const Vec2(130, 120)},
      graphics: {},
      markers: {'marker': const Vec2(330, 220)},
    );
    expect(app.sheet.wires.single.waypoints, [
      for (final point in wire.waypoints) point + const Vec2(30, 20),
    ]);
    app.undo();
    expect(app.sheet.wires.single.waypoints, wire.waypoints);
  });

  test('direct hover ignores hidden pages and caches within one snapshot', () {
    final hidden = _CountedSheet();
    final active = Sheet(
      id: 's',
      name: 'Direct',
      number: '1',
      devices: [
        _block('a', const Vec2(100, 100), PortSide.right),
        _block('b', const Vec2(300, 100), PortSide.left),
      ],
    );
    final project = syntheticProject(
      id: 'synthetic',
      name: 'Direct',
      pages: [active, hidden],
    );
    final resolver = ProjectResolver(project);
    final wire = resolver.wires(active).single;
    hidden.reads = 0;
    final info = resolveWireRouteHoverInfo(
      resolver: resolver,
      sheet: active,
      wireId: wire.id,
    );
    expect(info, isNotNull);
    expect(hidden.reads, 0);
    for (var i = 0; i < 10; i++) {
      expect(
        resolveWireRouteHoverInfo(
          resolver: resolver,
          sheet: active,
          wireId: wire.id,
        ),
        same(info),
      );
    }
    expect(hidden.reads, 0);
    final renamed = project.copyWith(
      components: [
        project.components.first.copyWith(designation: '-RENAMED'),
        ...project.components.skip(1),
      ],
    );
    final next = resolveWireRouteHoverInfo(
      resolver: ProjectResolver(renamed),
      sheet: active,
      wireId: wire.id,
    );
    expect(next, isNot(same(info)));
    expect(next!.label, contains('-RENAMED'));
    expect(info!.label, isNot(contains('-RENAMED')));
  });

  test(
    'corner hover reuses the route graph for another wire in the same scene',
    () {
      final hidden = _CountedSheet();
      final active = Sheet(
        id: 's',
        name: 'Corner',
        number: '1',
        devices: [
          _block('a', const Vec2(320, 200), PortSide.left),
          _block('b', const Vec2(200, 320), PortSide.top),
        ],
        corners: const [
          ConnectionCorner(id: 'corner', position: Vec2(200, 200)),
        ],
      );
      final project = syntheticProject(
        id: 'synthetic',
        name: 'Corner',
        pages: [active, hidden],
      );
      final resolver = ProjectResolver(project);
      final wires = resolver.wires(active);
      expect(wires, hasLength(2));
      hidden.reads = 0;
      final first = resolveWireRouteHoverInfo(
        resolver: resolver,
        sheet: active,
        wireId: wires.first.id,
      );
      expect(first, isNotNull);
      expect(hidden.reads, greaterThan(0));
      hidden.reads = 0;
      final second = resolveWireRouteHoverInfo(
        resolver: resolver,
        sheet: active,
        wireId: wires.last.id,
      );
      expect(second, isNotNull);
      expect(
        second!.label,
        anyOf(first!.label, '${first.to.label} → ${first.from.label}'),
      );
      expect(hidden.reads, 0);
    },
  );
}
