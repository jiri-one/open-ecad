// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import 'package:ecad_core/ecad_core.dart';
import 'package:test/test.dart';
import 'support.dart';

EcadProject fixture({
  bool vertical = false,
  bool bent = false,
  bool reverse = false,
}) {
  Device device(String id, Vec2 position, PortSide side) => Device(
    id: id,
    componentId: 'component_$id',
    functionId: 'function_$id',
    position: position,
    symbol: PortBlockSpec(
      width: 20,
      height: 20,
      ports: [
        BlockPort(
          id: 'p',
          terminalId: 'terminal_${id}_p',
          side: side,
          fraction: .5,
        ),
      ],
    ),
  );
  const a = TerminalRef(deviceId: 'a', portId: 'p');
  const b = TerminalRef(deviceId: 'b', portId: 'p');
  return syntheticProject(
    id: 'project',
    name: 'Corner insertion',
    pages: [
      Sheet(
        id: 'sheet',
        name: 'Wiring',
        number: '1',
        devices: [
          device(
            'a',
            vertical ? const Vec2(200, 100) : const Vec2(100, 200),
            vertical ? PortSide.bottom : PortSide.right,
          ),
          device(
            'b',
            bent || vertical ? const Vec2(200, 300) : const Vec2(300, 200),
            bent || vertical ? PortSide.top : PortSide.left,
          ),
        ],
        wires: [
          Wire(
            id: 'manual',
            from: reverse ? b : a,
            to: reverse ? a : b,
            waypoints: bent ? const [Vec2(200, 200)] : const [],
          ),
        ],
      ),
    ],
  );
}

bool connected(EcadProject project, WireEndpoint a, WireEndpoint b) {
  final sheet = project.pages.single, resolver = ProjectResolver(project);
  return ConnectivityIndex.build(
    project,
  ).connected(resolver.nodeFor(sheet, a)!, resolver.nodeFor(sheet, b)!);
}

void main() {
  const a = TerminalRef(deviceId: 'a', portId: 'p');
  const b = TerminalRef(deviceId: 'b', portId: 'p');
  for (final vertical in [false, true]) {
    for (final orientation in CornerOrientation.values) {
      for (final reverse in [false, true]) {
        test(
          'corner breaks an existing ${vertical ? 'vertical' : 'horizontal'} wire: ${orientation.name}, reversed $reverse',
          () {
            final original = fixture(vertical: vertical, reverse: reverse);
            final engine = ProjectEngine(original);
            expect(connected(original, a, b), isTrue);
            const position = Vec2(200, 200);
            final corner = ConnectionCorner(
              id: 'corner',
              position: position,
              orientation: orientation,
            );
            engine.execute([AddConnectionCorner('sheet', corner)]);
            final after = engine.project;
            expect(connected(after, a, b), isFalse);
            expect(after.pages.single.wires, hasLength(1));
            final wire = after.pages.single.wires.single;
            expect(wire.id, 'manual');
            expect(wire.to, isA<CornerRef>());
            final port = wire.to as CornerRef;
            final direction = corner.direction(port.portId)!;
            final expected =
                vertical
                    ? (direction.y > 0 ? b : a)
                    : (direction.x > 0 ? b : a);
            expect(wire.from, expected);
            expect(connected(after, expected, port), isTrue);
            final path = ProjectResolver(
              after,
            ).wirePath(after.pages.single, wire);
            expect(path.last, corner.portPosition(port.portId));
            expect(path, isNot(contains(position)));
            final reopened = EcadProject.fromJson(
              jsonDecode(jsonEncode(after.toJson())),
            );
            expect(connected(reopened, a, b), isFalse);
            engine.undo();
            expect(
              engine.project.pages.single.toJson(),
              original.pages.single.toJson(),
            );
            engine.redo();
            expect(
              engine.project.pages.single.toJson(),
              after.pages.single.toJson(),
            );
          },
        );
      }
    }
  }

  test('a matching elbow splits into two connections through the corner', () {
    final engine = ProjectEngine(fixture(bent: true));
    engine.execute([
      const AddConnectionCorner(
        'sheet',
        ConnectionCorner(
          id: 'corner',
          position: Vec2(200, 200),
          orientation: CornerOrientation.topRight,
        ),
      ),
    ]);
    final project = engine.project;
    expect(project.pages.single.wires, hasLength(2));
    expect(connected(project, a, b), isTrue);
    expect(
      project.pages.single.wires.every((w) => w.to.ownerId == 'corner'),
      isTrue,
    );
    expect(project.pages.single.wires.map((w) => w.id).toSet(), hasLength(2));
  });

  test(
    'a nearby corner leaves the route unchanged and moving onto it cuts it atomically',
    () {
      final original = fixture();
      final engine = ProjectEngine(original);
      const corner = ConnectionCorner(id: 'corner', position: Vec2(200, 210));
      engine.execute([const AddConnectionCorner('sheet', corner)]);
      expect(
        engine.project.pages.single.wires.single.toJson(),
        original.pages.single.wires.single.toJson(),
      );
      engine.execute([
        UpdateConnectionCorner(
          'sheet',
          corner.copyWith(position: const Vec2(200, 200)),
        ),
      ]);
      expect(connected(engine.project, a, b), isFalse);
      engine.undo();
      expect(connected(engine.project, a, b), isTrue);
    },
  );

  test('a routed loop cannot keep passing through the inserted corner', () {
    final original = fixture();
    final sheet = original.pages.single;
    final wire = sheet.wires.single.copyWith(
      waypoints: const [
        Vec2(200, 200),
        Vec2(200, 100),
        Vec2(250, 100),
        Vec2(250, 300),
        Vec2(200, 300),
        Vec2(200, 200),
      ],
    );
    final engine = ProjectEngine(
      original.copyWith(
        pages: [
          sheet.copyWith(wires: [wire]),
        ],
      ),
    );
    engine.execute([
      const AddConnectionCorner(
        'sheet',
        ConnectionCorner(
          id: 'corner',
          position: Vec2(200, 200),
          orientation: CornerOrientation.bottomLeft,
        ),
      ),
    ]);
    final result = engine.project.pages.single;
    expect(result.wires, hasLength(1));
    expect(result.wires.single.from, b);
    expect(result.wires.single.waypoints, isEmpty);
    expect(connected(engine.project, a, b), isFalse);
    expect(
      ProjectResolver(engine.project).wirePath(result, result.wires.single),
      [const Vec2(290, 200), const Vec2(210, 200)],
    );
  });

  test(
    'insufficient clearance rejects the whole insertion instead of restoring a through-wire',
    () {
      final original = fixture();
      final engine = ProjectEngine(original);
      expect(
        () => engine.execute([
          const AddConnectionCorner(
            'sheet',
            ConnectionCorner(id: 'corner', position: Vec2(285, 200)),
          ),
        ]),
        throwsA(
          isA<EcadException>().having(
            (error) => error.code,
            'code',
            'corner_clearance',
          ),
        ),
      );
      expect(engine.project, same(original));
      expect(engine.canUndo, isFalse);
      engine.execute([
        const AddConnectionCorner(
          'sheet',
          ConnectionCorner(id: 'corner', position: Vec2(280, 200)),
        ),
      ]);
      expect(connected(engine.project, a, b), isFalse);
    },
  );

  test(
    'a corner just off the wire leaves its geometry and connectivity intact',
    () {
      final original = fixture(bent: true);
      final engine = ProjectEngine(original);
      engine.execute([
        const AddConnectionCorner(
          'sheet',
          ConnectionCorner(id: 'corner', position: Vec2(150, 200.001)),
        ),
      ]);
      expect(
        engine.project.pages.single.wires.single.toJson(),
        original.pages.single.wires.single.toJson(),
      );
      expect(connected(engine.project, a, b), isTrue);
    },
  );

  test(
    'shared runs retain one editable connection per corner port and far endpoint',
    () {
      final base = fixture().pages.single;
      final sheet = base.copyWith(
        devices: [
          ...base.devices,
          Device(
            id: 'c',
            componentId: 'component_c',
            functionId: 'function_c',
            position: const Vec2(200, 300),
            symbol: PortBlockSpec(
              width: 20,
              height: 20,
              ports: const [
                BlockPort(
                  id: 'p',
                  terminalId: 'terminal_c_p',
                  side: PortSide.top,
                  fraction: .5,
                ),
              ],
            ),
          ),
        ],
        wires: [
          ...base.wires,
          Wire(
            id: 'ac',
            from: a,
            to: const TerminalRef(deviceId: 'c', portId: 'p'),
            waypoints: const [Vec2(200, 200)],
          ),
        ],
      );
      final original = syntheticProject(
        id: 'project',
        name: 'Shared runs',
        pages: [sheet],
      );
      const insert = AddConnectionCorner(
        'sheet',
        ConnectionCorner(
          id: 'corner',
          position: Vec2(200, 200),
          orientation: CornerOrientation.topRight,
        ),
      );
      for (final batch in [false, true]) {
        final engine = ProjectEngine(
          batch
              ? original.copyWith(pages: [sheet.copyWith(wires: [])])
              : original,
        );
        engine.execute([
          if (batch)
            for (final wire in sheet.wires) AddWire('sheet', wire),
          insert,
        ]);
        expect(engine.project.pages.single.wires, hasLength(2));
        for (final wire in engine.project.pages.single.wires) {
          engine.execute([UpdateWire('sheet', wire)]);
        }
        expect(connected(engine.project, a, b), isFalse);
        expect(
          connected(
            engine.project,
            a,
            const TerminalRef(deviceId: 'c', portId: 'p'),
          ),
          isTrue,
        );
      }
    },
  );

  for (final mode in ['insert', 'move', 'group']) {
    for (final gap in [0.0, 0.005]) {
      test('an arm cannot consume a retained bend: $mode, gap $gap', () {
        final engine = ProjectEngine(fixture(bent: true));
        const original = ConnectionCorner(
          id: 'corner',
          position: Vec2(190, 210),
        );
        if (mode != 'insert') {
          engine.execute([const AddConnectionCorner('sheet', original)]);
        }
        final before = engine.project;
        final corner = original.copyWith(position: Vec2(190 - gap, 200));
        expect(
          () => engine.execute([
            if (mode == 'insert')
              AddConnectionCorner('sheet', corner)
            else if (mode == 'move')
              UpdateConnectionCorner('sheet', corner)
            else
              UpdateSheet(before.pages.single.copyWith(corners: [corner])),
          ]),
          throwsA(
            isA<EcadException>().having(
              (error) => error.code,
              'code',
              'corner_clearance',
            ),
          ),
        );
        expect(engine.project, same(before));
      });
    }
  }

  test(
    'a retained bend keeps its geometry when there is a distinct run beyond the arm',
    () {
      for (final gap in [1.0, 10.0, 40.0]) {
        final engine = ProjectEngine(fixture(bent: true));
        final corner = ConnectionCorner(
          id: 'corner',
          position: Vec2(190 - gap, 200),
        );
        engine.execute([AddConnectionCorner('sheet', corner)]);
        final sheet = engine.project.pages.single;
        expect(
          ProjectResolver(engine.project).wirePath(sheet, sheet.wires.single),
          [const Vec2(200, 290), const Vec2(200, 200), Vec2(200 - gap, 200)],
        );
      }
    },
  );
}
