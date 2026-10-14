// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:math' as math;

import 'package:ecad_core/ecad_core.dart';
import 'package:test/test.dart';

Device _device(
  String id,
  DeviceKind kind,
  double x,
  double y, {
  double rotation = 0,
}) => Device(
  id: id,
  kind: kind,
  designation: '-$id',
  position: Vec2(x, y),
  rotation: rotation,
);

Wire _wire(
  String id,
  String from,
  String fromPort,
  String to,
  String toPort, [
  List<Vec2> waypoints = const [],
]) => Wire(
  id: id,
  from: TerminalRef(deviceId: from, portId: fromPort),
  to: TerminalRef(deviceId: to, portId: toPort),
  waypoints: waypoints,
);

Map<String, Device> _byId(List<Device> devices) => {
  for (final device in devices) device.id: device,
};

Vec2 _step(Vec2 a, Vec2 b) {
  final d = b - a;
  if (d.x.abs() < 1e-6 && d.y.abs() >= 1e-6) return Vec2(0, d.y.sign);
  if (d.y.abs() < 1e-6 && d.x.abs() >= 1e-6) return Vec2(d.x.sign, 0);
  return Vec2.zero;
}

/// Attached at both terminals, orthogonal without repeated, straight-through
/// or doubled-back points, leaving and entering along each terminal's axis
/// and outside both connected symbol bodies.
void _expectSound(List<Vec2> route, Wire wire, Map<String, Device> devices) {
  final start =
      WireRouter.terminal(devices[wire.from.deviceId]!, wire.from.portId)!;
  final end = WireRouter.terminal(devices[wire.to.deviceId]!, wire.to.portId)!;
  expect(route.first, start.point, reason: 'detached start $route');
  expect(route.last, end.point, reason: 'detached end $route');
  for (var i = 1; i < route.length; i++) {
    expect(_step(route[i - 1], route[i]), isNot(Vec2.zero), reason: '$route');
    if (i >= 2) {
      final before = _step(route[i - 2], route[i - 1]);
      final after = _step(route[i - 1], route[i]);
      expect(before.x * after.x + before.y * after.y, 0, reason: '$route');
    }
    for (final body in [start.body!, end.body!]) {
      expect(
        body.crosses(route[i - 1], route[i]),
        isFalse,
        reason: 'segment $i crosses a connected symbol: $route',
      );
    }
  }
  expect(_step(route[0], route[1]), start.direction, reason: '$route');
  expect(_step(route[route.length - 2], route.last), -end.direction);
}

void main() {
  group('shared orthogonal router', () {
    test('keeps straight runs and the grid-aligned middle jog', () {
      final devices = _byId([
        _device('q', DeviceKind.breaker, 200, 100),
        _device('h', DeviceKind.lamp, 200, 260),
        _device('k', DeviceKind.contactor, 330, 300),
      ]);
      expect(
        WireRouter.path(_wire('a', 'q', 'out', 'h', 'in'), devices),
        const [Vec2(200, 132), Vec2(200, 232)],
      );
      expect(
        WireRouter.path(_wire('b', 'q', 'out', 'k', 'in'), devices),
        const [Vec2(200, 132), Vec2(200, 200), Vec2(330, 200), Vec2(330, 268)],
      );
    });

    test('explicit aligned waypoints are drawn exactly as stored', () {
      final devices = _byId([
        _device('m', DeviceKind.motor, 120, 300),
        _device('x', DeviceKind.terminal, 300, 160),
      ]);
      const waypoints = [Vec2(220, 300), Vec2(220, 120), Vec2(300, 120)];
      expect(
        WireRouter.path(_wire('w', 'm', 'pe', 'x', 'in', waypoints), devices),
        const [Vec2(153, 300), ...waypoints, Vec2(300, 144)],
      );
    });

    test('every rotation and placement leaves both symbols cleanly', () {
      final pairs = [
        (DeviceKind.breaker, 'out', DeviceKind.lamp, 'in'),
        (DeviceKind.motor, 'pe', DeviceKind.terminal, 'in'),
        (DeviceKind.coil, 'a2', DeviceKind.contactNo, 'out'),
      ];
      for (final (fromKind, fromPort, toKind, toPort) in pairs) {
        for (final fromRotation in [0.0, 90.0, 180.0, 270.0]) {
          for (final toRotation in [0.0, 90.0, 180.0, 270.0]) {
            for (final dx in [-200.0, -40.0, 0.0, 40.0, 200.0]) {
              for (final dy in [-200.0, 0.0, 200.0]) {
                if (dx.abs() < 100 && dy.abs() < 100) continue;
                final devices = _byId([
                  _device('a', fromKind, 500, 400, rotation: fromRotation),
                  _device(
                    'b',
                    toKind,
                    500 + dx,
                    400 + dy,
                    rotation: toRotation,
                  ),
                ]);
                final wire = _wire('w', 'a', fromPort, 'b', toPort);
                _expectSound(WireRouter.path(wire, devices), wire, devices);
              }
            }
          }
        }
      }
    });

    test('symbols closer than the clearance still get a route between', () {
      final devices = _byId([
        _device('x', DeviceKind.terminal, 200, 100),
        _device('e', DeviceKind.earth, 200, 141, rotation: 90),
      ]);
      final wire = _wire('w', 'x', 'out', 'e', 'in');
      final route = WireRouter.path(wire, devices);
      _expectSound(route, wire, devices);
      expect(route[1], const Vec2(200, 118));
    });

    test('a stale waypoint behind a terminal cannot route through it', () {
      final devices = _byId([
        _device('m', DeviceKind.motor, 400, 300),
        _device('x', DeviceKind.terminal, 300, 160),
      ]);
      // The first waypoint lies on the far side of the motor.
      final wire = _wire('w', 'm', 'pe', 'x', 'in', const [
        Vec2(250, 300),
        Vec2(250, 120),
        Vec2(300, 120),
      ]);
      final route = WireRouter.path(wire, devices);
      _expectSound(route, wire, devices);
      expect(route[1], const Vec2(443, 300));
    });

    test('a waypoint inside a connected symbol is ignored', () {
      final devices = _byId([
        _device('m', DeviceKind.motor, 300, 400),
        _device('x', DeviceKind.terminal, 520, 300),
      ]);
      final wire = _wire('w', 'm', 'pe', 'x', 'in', const [
        Vec2(300, 400),
        Vec2(520, 260),
      ]);
      final route = WireRouter.path(wire, devices);
      _expectSound(route, wire, devices);
      expect(route, contains(const Vec2(520, 260)));
    });

    test('joined legs still meet both terminals from outside', () {
      // Each leg alone is valid, but doubling back over the last bend would
      // merge into a final run reaching the left-facing terminal from below.
      final devices = _byId([
        _device('x', DeviceKind.terminal, 320, 560, rotation: 270),
        _device('s', DeviceKind.contactNo, 380, 270, rotation: 90),
      ]);
      final wire = _wire('w', 'x', 'out', 's', 'out', const [
        Vec2(350, 560),
        Vec2(290, 270),
      ]);
      _expectSound(WireRouter.path(wire, devices), wire, devices);
    });

    test('a free end, such as the pointer, has no direction or body', () {
      const breaker = Device(
        id: 'q',
        kind: DeviceKind.breaker,
        designation: '-Q',
        position: Vec2(100, 100),
      );
      final start = WireRouter.terminal(breaker, 'out')!;
      final route = WireRouter.route(start, const WireTerminal(Vec2(100, 40)));
      expect(route.first, start.point);
      expect(route.last, const Vec2(100, 40));
      expect(_step(route[0], route[1]), start.direction);
      for (var i = 1; i < route.length; i++) {
        expect(start.body!.crosses(route[i - 1], route[i]), isFalse);
      }
      expect(WireRouter.terminal(breaker, 'missing'), isNull);
    });
  });

  group('manual bends follow moved terminals', () {
    final motor = _device('m', DeviceKind.motor, 200, 300);
    final terminal = _device('x', DeviceKind.terminal, 420, 200);
    final wire = _wire('w', 'm', 'pe', 'x', 'in', const [
      Vec2(330, 300),
      Vec2(330, 160),
      Vec2(420, 160),
    ]);
    final before = _byId([motor, terminal]);

    test('moving past the first bend moves that track outward', () {
      final after = _byId([
        motor.copyWith(position: const Vec2(500, 300)),
        terminal,
      ]);
      expect(WireRouter.path(wire, after)[1].x, greaterThan(533));
      final followed = WireRouter.follow(wire, before, after);
      expect(followed.waypoints, const [
        Vec2(550, 300),
        Vec2(550, 160),
        Vec2(420, 160),
      ]);
      final route = WireRouter.path(followed, after);
      _expectSound(route, followed, after);
      expect(route, const [
        Vec2(533, 300),
        Vec2(550, 300),
        Vec2(550, 160),
        Vec2(420, 160),
        Vec2(420, 184),
      ]);
    });

    test('a sideways move slides only the adjacent run', () {
      final after = _byId([
        motor.copyWith(position: const Vec2(180, 260)),
        terminal,
      ]);
      final followed = WireRouter.follow(wire, before, after);
      expect(followed.waypoints, const [
        Vec2(330, 260),
        Vec2(330, 160),
        Vec2(420, 160),
      ]);
      _expectSound(WireRouter.path(followed, after), followed, after);
    });

    test('rotation keeps a straight outward departure', () {
      for (final rotation in [90.0, 180.0, 270.0]) {
        final after = _byId([motor.copyWith(rotation: rotation), terminal]);
        final followed = WireRouter.follow(wire, before, after);
        _expectSound(WireRouter.path(followed, after), followed, after);
        expect(followed.waypoints.last, const Vec2(420, 160));
      }
    });

    test('terminals that move together translate the whole route', () {
      const shift = Vec2(-60, 40);
      final after = _byId([
        motor.copyWith(position: motor.position + shift),
        terminal.copyWith(position: terminal.position + shift),
      ]);
      expect(WireRouter.follow(wire, before, after).waypoints, [
        for (final point in wire.waypoints) point + shift,
      ]);
    });

    test('unchanged terminals and automatic routes are kept as is', () {
      final renamed = _byId([motor.copyWith(designation: '-M2'), terminal]);
      expect(identical(WireRouter.follow(wire, before, renamed), wire), isTrue);
      final automatic = _wire('a', 'm', 'in', 'x', 'out');
      final moved = _byId([
        motor.copyWith(position: const Vec2(0, 0)),
        terminal,
      ]);
      expect(
        identical(WireRouter.follow(automatic, before, moved), automatic),
        isTrue,
      );
    });

    test('bends that cannot follow safely are not stored', () {
      // Rotating the contact would slide the shared corner into the coil;
      // moving the terminal past both bends would reach the contact sideways.
      final cases = <(List<Device>, Wire, EcadCommand)>[
        (
          [
            _device('a', DeviceKind.coil, 230, 470),
            _device('b', DeviceKind.contactNo, 350, 500, rotation: 270),
          ],
          _wire('w', 'a', 'a2', 'b', 'in', const [Vec2(230, 500)]),
          UpdateDevice('s', _device('b', DeviceKind.contactNo, 350, 500)),
        ),
        (
          [
            _device('a', DeviceKind.terminal, 210, 590, rotation: 270),
            _device('b', DeviceKind.contactNo, 380, 270, rotation: 90),
          ],
          _wire('w', 'a', 'out', 'b', 'out', const [
            Vec2(290, 590),
            Vec2(290, 270),
          ]),
          MoveDevices('s', {'a': const Vec2(320, 560)}),
        ),
      ];
      for (final (devices, wire, edit) in cases) {
        _expectSound(
          WireRouter.path(wire, _byId(devices)),
          wire,
          _byId(devices),
        );
        final engine = ProjectEngine(
          EcadProject(
            id: 'p',
            name: 'P',
            pages: [
              Sheet(
                id: 's',
                name: 'S',
                number: '1',
                devices: devices,
                wires: [wire],
              ),
            ],
          ),
        );
        engine.execute([edit]);
        final sheet = engine.project.pages.single;
        final moved = sheet.wires.single;
        final after = _byId(sheet.devices);
        _expectSound(WireRouter.path(moved, after), moved, after);
        for (final end in [moved.from, moved.to]) {
          final body = WireRouter.terminal(after[end.deviceId]!, end.portId)!;
          for (final point in moved.waypoints) {
            expect(
              point.x > body.body!.left &&
                  point.x < body.body!.right &&
                  point.y > body.body!.top &&
                  point.y < body.body!.bottom,
              isFalse,
              reason: 'stored bend $point inside ${end.deviceId}',
            );
          }
        }
      }
    });

    test('random edits keep bends visible and match the commit', () {
      final random = math.Random(14102026);
      double grid(int steps) => (random.nextInt(steps) * 10 + 100).toDouble();
      Device place(String id) => _device(
        id,
        DeviceKind.values[random.nextInt(DeviceKind.values.length)],
        grid(60),
        grid(50),
        rotation: random.nextInt(4) * 90.0,
      );
      String port(Device device) {
        final ports = SymbolCatalog.definitionFor(device.kind).ports;
        return ports[random.nextInt(ports.length)].id;
      }

      RouteBox body(Device device) =>
          WireRouter.terminal(
            device,
            SymbolCatalog.definitionFor(device.kind).ports.first.id,
          )!.body!;
      // Clearly separated symbols; overlapping ones are best effort only.
      bool apart(Device a, Device b) {
        const gap = 40;
        final p = body(a);
        final q = body(b);
        return p.right + gap <= q.left ||
            q.right + gap <= p.left ||
            p.bottom + gap <= q.top ||
            q.bottom + gap <= p.top;
      }

      var trials = 0;
      while (trials < 1000) {
        final a = place('a');
        final b = place('b');
        if (!apart(a, b)) continue;
        final before = _byId([a, b]);
        final automatic = _wire('w', 'a', port(a), 'b', port(b));
        final route = WireRouter.path(automatic, before);
        _expectSound(route, automatic, before);
        if (route.length < 3) continue;
        final wire = automatic.copyWith(
          waypoints: route.sublist(1, route.length - 1),
        );
        final edit = random.nextInt(5);
        final target = Vec2(grid(60), grid(50));
        final shift = target - a.position;
        final movedA = switch (edit) {
          0 => a.copyWith(position: target),
          2 => a.copyWith(rotation: (a.rotation + 90) % 360),
          4 => a.copyWith(position: a.position + shift),
          _ => a,
        };
        final movedB = switch (edit) {
          1 => b.copyWith(position: target),
          3 => b.copyWith(rotation: (b.rotation + 90) % 360),
          4 => b.copyWith(position: b.position + shift),
          _ => b,
        };
        if (!apart(movedA, movedB)) continue;
        trials++;
        final after = _byId([movedA, movedB]);
        final followed = WireRouter.follow(wire, before, after);
        final followedRoute = WireRouter.path(followed, after);
        _expectSound(followedRoute, followed, after);
        for (final bend in followed.waypoints) {
          // Equality in the triangle inequality means this bend lies on a
          // rendered segment, including a bend inside a straight run.
          expect(
            [
              for (var i = 1; i < followedRoute.length; i++)
                followedRoute[i - 1].distanceTo(bend) +
                    bend.distanceTo(followedRoute[i]) -
                    followedRoute[i - 1].distanceTo(followedRoute[i]),
            ],
            anyElement(closeTo(0, 1e-6)),
            reason: 'stored bend $bend is absent from $followedRoute',
          );
        }
        final engine = ProjectEngine(
          EcadProject(
            id: 'p',
            name: 'P',
            pages: [
              Sheet(
                id: 's',
                name: 'S',
                number: '1',
                devices: [a, b],
                wires: [wire],
              ),
            ],
          ),
        );
        engine.execute([
          if (edit == 2 || edit == 3)
            UpdateDevice('s', edit == 2 ? movedA : movedB)
          else
            MoveDevices('s', {'a': movedA.position, 'b': movedB.position}),
        ]);
        expect(
          engine.project.pages.single.wires.single.waypoints,
          followed.waypoints,
        );
      }
    });
  });

  group('engine keeps attached geometry', () {
    // An invented branch: one source terminal feeds a coil directly and a
    // lamp through a manual T-route whose branch point lies on the coil wire.
    EcadProject branch() => EcadProject(
      id: 'routing',
      name: 'Routing',
      pages: [
        Sheet(
          id: 's',
          name: 'Branch',
          number: '1',
          devices: [
            _device('s1', DeviceKind.contactNo, 200, 100),
            _device('k1', DeviceKind.coil, 200, 300),
            _device('h1', DeviceKind.lamp, 420, 300),
          ],
          wires: [
            _wire('direct', 's1', 'out', 'k1', 'a1'),
            _wire('tee', 's1', 'out', 'h1', 'in', const [
              Vec2(200, 200),
              Vec2(420, 200),
            ]),
          ],
        ),
      ],
    );

    test('moves and rotations commit adjusted bends as one undo step', () {
      final engine = ProjectEngine(branch());
      final original = engine.project.toJson();
      engine.execute([
        MoveDevices('s', {'h1': const Vec2(520, 160)}),
      ]);
      final sheet = engine.project.pages.single;
      final tee = sheet.wires.last;
      // The lamp now sits above the old bend: that bend moves above the lamp,
      // while the branch point on the coil wire stays where it was.
      expect(tee.waypoints, const [Vec2(200, 200), Vec2(520, 120)]);
      _expectSound(
        WireRouter.path(tee, _byId(sheet.devices)),
        tee,
        _byId(sheet.devices),
      );
      expect(
        WireRouter.path(tee, _byId(sheet.devices)),
        contains(const Vec2(200, 200)),
      );
      expect(
        sheet.wires.first.toJson(),
        branch().pages.single.wires.first.toJson(),
      );
      final moved = engine.project.toJson();
      expect(engine.undo(), isTrue);
      expect(engine.project.toJson(), {
        ...original,
        'revision': engine.project.revision,
      });
      expect(engine.redo(), isTrue);
      expect(engine.project.toJson(), {
        ...moved,
        'revision': engine.project.revision,
      });

      final source = engine.project.pages.single.deviceById('s1')!;
      engine.execute([UpdateDevice('s', source.copyWith(rotation: 180))]);
      final rotated = engine.project.pages.single;
      final devices = _byId(rotated.devices);
      for (final wire in rotated.wires) {
        _expectSound(WireRouter.path(wire, devices), wire, devices);
      }
    });

    test('shared terminal branches stay attached after moving any side', () {
      for (final move in [
        {'s1': const Vec2(320, 60)},
        {'k1': const Vec2(80, 360)},
        {'h1': const Vec2(260, 420)},
        {'s1': const Vec2(260, 140), 'h1': const Vec2(480, 340)},
      ]) {
        final engine = ProjectEngine(branch());
        engine.execute([MoveDevices('s', move)]);
        final sheet = engine.project.pages.single;
        final devices = _byId(sheet.devices);
        final port = worldPortPosition(devices['s1']!, 'out');
        for (final wire in sheet.wires) {
          final route = WireRouter.path(wire, devices);
          expect(route.first, port);
          _expectSound(route, wire, devices);
        }
      }
    });
  });
}
