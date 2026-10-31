// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import 'package:ecad_core/ecad_core.dart';
import 'package:test/test.dart';
import 'support.dart';

Device block(
  String id,
  Vec2 at,
  PortSide side, {
  OccurrenceMode mode = OccurrenceMode.wiring,
}) => Device(
  id: id,
  componentId: 'component_$id',
  functionId: 'function_$id',
  position: at,
  mode: mode,
  symbol: PortBlockSpec(
    width: 20,
    height: 20,
    ports: [
      BlockPort(
        id: 'port',
        terminalId: 'terminal_$id',
        side: side,
        fraction: .5,
      ),
    ],
  ),
);
const a = TerminalRef(deviceId: 'a', portId: 'port');
const b = TerminalRef(deviceId: 'b', portId: 'port');
Sheet sheet(
  List<Device> devices, {
  List<ConnectionCorner> corners = const [],
  List<Wire> wires = const [],
}) => Sheet(
  id: 'sheet',
  name: 'Synthetic',
  number: '1',
  devices: devices,
  corners: corners,
  wires: wires,
);
EcadProject project(Sheet s) =>
    syntheticProject(id: 'project', name: 'Synthetic', pages: [s]);

void main() {
  test('opposing horizontal and vertical terminals form real nets', () {
    for (final vertical in [false, true]) {
      final s = sheet([
        block(
          'a',
          const Vec2(100, 100),
          vertical ? PortSide.bottom : PortSide.right,
        ),
        block(
          'b',
          vertical ? const Vec2(100, 300) : const Vec2(300, 100),
          vertical ? PortSide.top : PortSide.left,
        ),
      ]);
      final p = project(s), r = ProjectResolver(project(s));
      final wires = r.wires(s);
      expect(wires, hasLength(1));
      expect(wires.single.isAutomatic, isTrue);
      expect(r.wirePath(s, wires.single), hasLength(2));
      expect(
        ConnectivityIndex.build(
          p,
        ).connected(r.nodeFor(s, a)!, r.nodeFor(s, b)!),
        isTrue,
      );
      expect(
        validateProject(p).where((d) => d.code == 'unconnected_port'),
        isEmpty,
      );
      expect(s.wires, isEmpty);
    }
  });

  test(
    'wrong directions, offset parallel rows and references do not connect',
    () {
      for (final side in [PortSide.right, PortSide.top, PortSide.bottom]) {
        expect(
          AutoConnect.wires(
            sheet([
              block('a', const Vec2(100, 100), PortSide.right),
              block('b', const Vec2(300, 100), side),
            ]),
          ),
          isEmpty,
        );
      }
      for (final offset in [.001, 1.0, 20.0]) {
        expect(
          AutoConnect.wires(
            sheet([
              block('a', const Vec2(100, 100), PortSide.right),
              block('b', Vec2(300, 100 + offset), PortSide.left),
            ]),
          ),
          isEmpty,
        );
      }
      expect(
        AutoConnect.wires(
          sheet([
            block('a', const Vec2(100, 100), PortSide.right),
            block(
              'b',
              const Vec2(300, 100),
              PortSide.left,
              mode: OccurrenceMode.reference,
            ),
          ]),
        ),
        isEmpty,
      );
      expect(
        AutoConnect.wires(
          sheet([
            block('a', const Vec2(100, 100), PortSide.right),
            block('b', const Vec2(300, 100.00000001), PortSide.left),
          ]),
        ),
        hasLength(1),
      );
    },
  );

  test('the nearest port stops a ray and foreign symbol bodies block it', () {
    final source = block('a', const Vec2(100, 100), PortSide.right);
    final target = block('b', const Vec2(400, 100), PortSide.left);
    final near = block('near', const Vec2(250, 100), PortSide.left);
    final wires = AutoConnect.wires(sheet([target, source, near]));
    expect(wires, hasLength(1));
    expect(wires.single.to.ownerId, 'near');
    for (final mode in OccurrenceMode.values) {
      final obstacle = block(
        'obstacle',
        const Vec2(250, 100),
        PortSide.top,
        mode: mode,
      );
      expect(AutoConnect.wires(sheet([source, obstacle, target])), isEmpty);
    }
    final explicit = Wire(
      id: 'manual',
      from: const TerminalRef(deviceId: 'near', portId: 'port'),
      to: b,
    );
    expect(
      AutoConnect.automaticWires(
        sheet([source, near, target], wires: [explicit]),
      ),
      isEmpty,
    );
  });

  test('explicit routes take precedence without duplicate automatic edges', () {
    final s = sheet([
      block('a', const Vec2(100, 100), PortSide.right),
      block('b', const Vec2(300, 100), PortSide.left),
    ]);
    final engine = ProjectEngine(project(s));
    final manual = Wire(
      id: 'manual',
      from: b,
      to: a,
      waypoints: const [Vec2(250, 100)],
    );
    engine.execute([AddWire(s.id, manual)]);
    expect(AutoConnect.wires(engine.project.pages.single), [manual]);
    expect(
      () => engine.execute([
        AddWire(s.id, Wire(id: 'duplicate', from: a, to: b)),
      ]),
      throwsA(isA<EcadException>()),
    );
    engine.execute([DeleteWire(s.id, manual.id)]);
    expect(
      AutoConnect.wires(engine.project.pages.single).single.isAutomatic,
      isTrue,
    );
  });

  test(
    'four orientations connect their two arms to one logical node, never BOM',
    () {
      for (final orientation in CornerOrientation.values) {
        final corner = ConnectionCorner(
          id: 'corner',
          position: const Vec2(200, 200),
          orientation: orientation,
        );
        PortSide facing(Vec2 d) =>
            d.x > 0
                ? PortSide.left
                : d.x < 0
                ? PortSide.right
                : d.y > 0
                ? PortSide.top
                : PortSide.bottom;
        final s = sheet([
          block(
            'a',
            corner.position + orientation.a * 100,
            facing(orientation.a),
          ),
          block(
            'b',
            corner.position + orientation.b * 100,
            facing(orientation.b),
          ),
        ]);
        final engine = ProjectEngine(project(s));
        final originalBom =
            buildBom(
              engine.project,
            ).components.map((r) => r.component.toJson()).toList();
        engine.execute([AddConnectionCorner(s.id, corner)]);
        final next = engine.project.pages.single,
            r = ProjectResolver(engine.project);
        expect(r.wires(next), hasLength(2));
        expect(
          ConnectivityIndex.build(
            engine.project,
          ).connected(r.nodeFor(next, a)!, r.nodeFor(next, b)!),
          isTrue,
        );
        expect(
          r.nodeFor(next, const CornerRef(cornerId: 'corner', portId: 'a')),
          r.nodeFor(next, const CornerRef(cornerId: 'corner', portId: 'b')),
        );
        expect(
          buildBom(
            engine.project,
          ).components.map((r) => r.component.toJson()).toList(),
          originalBom,
        );
        final loaded = EcadProject.fromJson(
          jsonDecode(jsonEncode(engine.project.toJson())),
        );
        expect(AutoConnect.wires(loaded.pages.single), hasLength(2));
        expect(loaded.pages.single.corners.single.orientation, orientation);
        expect(loaded.components, hasLength(2));
      }
    },
  );

  test(
    'a route through several corners survives undo, redo, rotation and deletion',
    () {
      final s = sheet(
        [
          block('a', const Vec2(100, 100), PortSide.right),
          block('b', const Vec2(400, 300), PortSide.left),
        ],
        corners: const [
          ConnectionCorner(
            id: 'c1',
            position: Vec2(250, 100),
            orientation: CornerOrientation.topRight,
          ),
          ConnectionCorner(
            id: 'c2',
            position: Vec2(250, 300),
            orientation: CornerOrientation.bottomLeft,
          ),
        ],
      );
      final engine = ProjectEngine(project(s));
      bool connected() {
        final r = ProjectResolver(engine.project),
            current = engine.project.pages.single;
        return ConnectivityIndex.build(
          engine.project,
        ).connected(r.nodeFor(current, a)!, r.nodeFor(current, b)!);
      }

      expect(connected(), isTrue);
      final c = s.corners.first;
      engine.execute([
        UpdateConnectionCorner(
          s.id,
          c.copyWith(position: const Vec2(260, 100)),
        ),
      ]);
      expect(connected(), isFalse);
      engine.undo();
      expect(connected(), isTrue);
      engine.redo();
      expect(connected(), isFalse);
      engine.undo();
      engine.execute([
        UpdateConnectionCorner(
          s.id,
          c.copyWith(orientation: c.orientation.rotated),
        ),
      ]);
      expect(connected(), isFalse);
      engine.undo();
      expect(connected(), isTrue);
      engine.execute([DeleteConnectionCorner(s.id, c.id)]);
      expect(connected(), isFalse);
      engine.undo();
      expect(connected(), isTrue);
    },
  );

  test(
    'manual corner wire and anchors remain stored after moving and rotating',
    () {
      final c = ConnectionCorner(id: 'corner', position: const Vec2(200, 200));
      final wire = Wire(
        id: 'manual',
        from: a,
        to: const CornerRef(cornerId: 'corner', portId: 'a'),
        waypoints: const [
          Vec2(140, 100),
          Vec2(140, 170),
          Vec2(240, 170),
          Vec2(240, 200),
        ],
      );
      final engine = ProjectEngine(
        project(
          sheet(
            [block('a', const Vec2(100, 100), PortSide.right)],
            corners: [c],
            wires: [wire],
          ),
        ),
      );
      engine.execute([
        UpdateConnectionCorner(
          'sheet',
          c.copyWith(
            position: const Vec2(300, 300),
            orientation: CornerOrientation.bottomRight,
          ),
        ),
      ]);
      final moved = engine.project.pages.single.wires.single;
      expect(moved.from, a);
      expect(moved.to, wire.to);
      expect(moved.waypoints, hasLength(4));
      final reopened = EcadProject.fromJson(
        jsonDecode(jsonEncode(engine.project.toJson())),
      );
      expect(reopened.pages.single.wires.single.toJson(), moved.toJson());
      engine.undo();
      expect(engine.project.pages.single.wires.single.toJson(), wire.toJson());
      engine.execute([DeleteConnectionCorner('sheet', c.id)]);
      expect(engine.project.pages.single.wires, isEmpty);
      engine.undo();
      expect(engine.project.pages.single.wires.single.toJson(), wire.toJson());
    },
  );

  test(
    'old v4 sheets without corners open; equal IDs in different projects stay independent',
    () {
      final s = sheet([
        block('a', const Vec2(100, 100), PortSide.right),
        block('b', const Vec2(300, 100), PortSide.left),
      ]);
      final p = project(s), r = ProjectResolver(project(s));
      final json = p.toJson();
      expect((json['pages'] as List).single, isNot(contains('corners')));
      final reopened = EcadProject.fromJson(jsonDecode(jsonEncode(json)));
      final other = p.copyWith(
        pages: [
          s.copyWith(
            devices: [
              s.devices.first,
              s.devices.last.copyWith(position: const Vec2(300, 110)),
            ],
          ),
        ],
      );
      expect(AutoConnect.wires(reopened.pages.single), hasLength(1));
      expect(ProjectResolver(other).wires(other.pages.single), isEmpty);
      expect(
        ConnectivityIndex.build(
          other,
        ).connected(r.nodeFor(s, a)!, r.nodeFor(s, b)!),
        isFalse,
      );
      final split = p.copyWith(
        pages: [
          s.copyWith(devices: [s.devices.first]),
          s.copyWith(id: 'other_sheet', number: '2', devices: [s.devices.last]),
        ],
      );
      expect(split.pages.expand(AutoConnect.wires), isEmpty);
    },
  );

  test(
    'two coincident facing ports join; ambiguous co-located ports do not',
    () {
      final s = sheet(
        [],
        corners: const [
          ConnectionCorner(id: 'c1', position: Vec2(100, 100)),
          ConnectionCorner(
            id: 'c2',
            position: Vec2(120, 100),
            orientation: CornerOrientation.topRight,
          ),
        ],
      );
      expect(AutoConnect.wires(s), hasLength(1));
      expect(
        AutoConnect.wires(
          s.copyWith(
            corners: [
              ...s.corners,
              const ConnectionCorner(id: 'c3', position: Vec2(100, 100)),
            ],
          ),
        ),
        isEmpty,
      );
    },
  );
  test(
    'corner command round trip validates local port references atomically',
    () {
      final engine = ProjectEngine(
        project(sheet([block('a', const Vec2(100, 100), PortSide.right)])),
      );
      const corner = ConnectionCorner(id: 'corner', position: Vec2(250, 200));
      for (final command in [
        const AddConnectionCorner('sheet', corner),
        UpdateConnectionCorner(
          'sheet',
          corner.copyWith(orientation: CornerOrientation.bottomLeft),
        ),
      ]) {
        engine.execute([
          EcadCommand.fromJson(jsonDecode(jsonEncode(command.toJson()))),
        ]);
      }
      final snapshot = engine.project;
      for (final endpoint in [
        const CornerRef(cornerId: 'missing', portId: 'a'),
        const CornerRef(cornerId: 'corner', portId: 'unknown'),
      ]) {
        expect(
          () => engine.execute([
            AddWire('sheet', Wire(id: 'wire', from: a, to: endpoint)),
          ]),
          throwsA(
            isA<EcadException>().having(
              (e) => e.code,
              'code',
              'invalid_corner_endpoint',
            ),
          ),
        );
        expect(engine.project, same(snapshot));
      }
      engine.execute([
        EcadCommand.fromJson(
          const DeleteConnectionCorner('sheet', 'corner').toJson(),
        ),
      ]);
      expect(engine.project.pages.single.corners, isEmpty);
      engine.undo();
      expect(
        engine.project.pages.single.corners.single.orientation,
        CornerOrientation.bottomLeft,
      );
    },
  );
}
