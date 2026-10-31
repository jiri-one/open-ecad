// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:ecad_core/ecad_core.dart' show PortSide, Vec2;
import 'package:ecad_core/terminal_symbol_geometry.dart';
import 'package:flutter_test/flutter_test.dart';

const _clockwise = [
  PortSide.top,
  PortSide.right,
  PortSide.bottom,
  PortSide.left,
];
const _normals = [Vec2(0, -1), Vec2(1, 0), Vec2(0, 1), Vec2(-1, 0)];

Set<PortSide> _sides(int mask) => {
  for (var index = 0; index < 4; index++)
    if (mask & (1 << index) != 0) _clockwise[index],
};

void main() {
  for (var mask = 1; mask < 16; mask++) {
    test(
      'combination $mask has exact cardinal arms, ports and stable keys',
      () {
        final sides = _sides(mask);
        for (final center in [
          Vec2.zero,
          const Vec2(30, -50),
          const Vec2(.5, -1.25),
        ]) {
          for (final turns in [-5, -1, 0, 1, 2, 3, 4, 9]) {
            for (final (radius, distance) in [
              (2.0, 5.0),
              (4.0, 10.0),
              (7.0, 20.0),
            ]) {
              final geometry = TerminalSymbolGeometry(
                sides: sides.toList().reversed,
                center: center,
                radius: radius,
                portDistance: distance,
                quarterTurns: turns,
              );
              expect(geometry.center, center);
              expect(geometry.radius, radius);
              expect(geometry.quarterTurns, turns % 4);
              expect(geometry.ports, hasLength(sides.length));
              expect(geometry.arms, hasLength(sides.length));
              expect(
                geometry.ports.map((port) => port.key),
                sides.map((side) => side.name),
              );
              expect(geometry.sides, orderedEquals(sides));
              for (final port in geometry.ports) {
                final index = (_clockwise.indexOf(port.localSide) + turns) % 4;
                expect(port.side, _clockwise[index]);
                expect(port.normal, _normals[index]);
                expect(port.normal.lengthSquared, 1);
                expect(port.key, port.localSide.name);
                expect(port.position, center + _normals[index] * distance);
                final arm = geometry.arms.singleWhere(
                  (arm) => arm.port.key == port.key,
                );
                expect(identical(arm.port, port), isTrue);
                expect(arm.start, center + _normals[index] * radius);
                expect(arm.end, port.position);
                expect(arm.start.distanceTo(center), closeTo(radius, 1e-10));
                expect(
                  (arm.end - arm.start).length,
                  closeTo(distance - radius, 1e-10),
                );
              }
            }
          }
        }
      },
    );
  }

  test(
    'snapped centers keep ports on the grid for all combinations and rotations',
    () {
      for (final grid in [5.0, 10.0, 20.0]) {
        final center = const Vec2(127, -33).snapped(grid);
        for (var mask = 1; mask < 16; mask++) {
          for (var turns = 0; turns < 4; turns++) {
            final geometry = TerminalSymbolGeometry(
              sides: _sides(mask),
              center: center,
              radius: grid * .4,
              portDistance: grid,
              quarterTurns: turns,
            );
            expect(geometry.center, center);
            for (final port in geometry.ports) {
              expect(port.position.snapped(grid), port.position);
            }
          }
        }
      }
      final defaults = TerminalSymbolGeometry(sides: _clockwise);
      expect(defaults.portDistance, 10);
      expect(defaults.radius, lessThan(defaults.portDistance));
    },
  );

  test(
    'retained directions keep their keys when another direction is removed',
    () {
      final full = TerminalSymbolGeometry(sides: _clockwise, quarterTurns: 1);
      final reduced = TerminalSymbolGeometry(
        sides: {PortSide.top, PortSide.left},
        quarterTurns: 1,
      );
      for (final port in reduced.ports) {
        final previous = full.ports.singleWhere(
          (candidate) => candidate.key == port.key,
        );
        expect(port.position, previous.position);
        expect(port.normal, previous.normal);
      }
      expect(reduced.ports.map((port) => port.key), ['top', 'left']);
    },
  );

  test(
    'inputs are copied and all exposed geometry collections are immutable',
    () {
      final input = {PortSide.left, PortSide.right};
      final geometry = TerminalSymbolGeometry(sides: input);
      input.clear();
      expect(geometry.sides, {PortSide.left, PortSide.right});
      expect(() => geometry.sides.clear(), throwsUnsupportedError);
      expect(() => geometry.ports.clear(), throwsUnsupportedError);
      expect(() => geometry.arms.clear(), throwsUnsupportedError);
      final duplicate = TerminalSymbolGeometry(
        sides: [PortSide.top, PortSide.top],
      );
      expect(duplicate.ports, hasLength(1));
    },
  );

  test('invalid circles and empty symbols are rejected', () {
    expect(() => TerminalSymbolGeometry(sides: []), throwsArgumentError);
    for (final invalid in [0.0, -1.0, double.nan, double.infinity]) {
      expect(
        () => TerminalSymbolGeometry(sides: _clockwise, radius: invalid),
        throwsArgumentError,
      );
      expect(
        () => TerminalSymbolGeometry(sides: _clockwise, portDistance: invalid),
        throwsArgumentError,
      );
    }
    for (final distance in [3.0, 4.0]) {
      expect(
        () => TerminalSymbolGeometry(
          sides: _clockwise,
          radius: 4,
          portDistance: distance,
        ),
        throwsArgumentError,
      );
    }
    for (final center in [
      const Vec2(double.nan, 0),
      const Vec2(0, double.infinity),
    ]) {
      expect(
        () => TerminalSymbolGeometry(sides: _clockwise, center: center),
        throwsArgumentError,
      );
    }
  });

  test(
    'bounds enclose the actual primitives but do not define a rectangular hit area',
    () {
      final geometry = TerminalSymbolGeometry(
        sides: _clockwise,
        center: const Vec2(30, 50),
      );
      expect(geometry.bounds.x, 20);
      expect(geometry.bounds.y, 40);
      expect(geometry.bounds.width, 20);
      expect(geometry.bounds.height, 20);
      expect(geometry.hitTest(const Vec2(30, 50), tolerance: 0), isTrue);
      for (final port in geometry.ports) {
        expect(geometry.hitTest(port.position, tolerance: 0), isTrue);
      }
      for (final corner in [
        const Vec2(20, 40),
        const Vec2(40, 40),
        const Vec2(20, 60),
        const Vec2(40, 60),
      ]) {
        expect(geometry.hitTest(corner), isFalse);
      }
      expect(geometry.hitTest(const Vec2(31, 40), tolerance: 1), isTrue);
      expect(geometry.hitTest(const Vec2(32, 40), tolerance: 1), isFalse);
      expect(geometry.hitTest(const Vec2(30, 39), tolerance: 1), isTrue);
      expect(geometry.hitTest(const Vec2(30, 38), tolerance: 1), isFalse);
      expect(geometry.hitTest(const Vec2(double.nan, 0)), isFalse);
      expect(
        () => geometry.hitTest(Vec2.zero, tolerance: -1),
        throwsArgumentError,
      );

      final single = TerminalSymbolGeometry(
        sides: {PortSide.top},
        quarterTurns: 1,
      );
      expect(single.bounds.x, -4);
      expect(single.bounds.y, -4);
      expect(single.bounds.width, 14);
      expect(single.bounds.height, 8);
      expect(single.hitTest(const Vec2(0, -10), tolerance: 0), isFalse);
      expect(single.hitTest(const Vec2(10, 0), tolerance: 0), isTrue);
    },
  );

  test(
    'label rows stay outside the circle and clear of cardinal conductors',
    () {
      for (var mask = 1; mask < 16; mask++) {
        for (var turns = 0; turns < 4; turns++) {
          final geometry = TerminalSymbolGeometry(
            sides: _sides(mask),
            center: const Vec2(40, 70),
            quarterTurns: turns,
          );
          final layout = geometry.labelLayout(lineHeight: 14, gap: 6);
          expect(layout.designationOrigin, const Vec2(56, 53));
          expect(layout.numberOrigin, const Vec2(56, 73));
          expect(
            layout.designationOrigin.x,
            greaterThan(geometry.bounds.x + geometry.bounds.width),
          );
          expect(
            layout.designationOrigin.y + layout.lineHeight,
            lessThan(geometry.center.y),
          );
          expect(layout.numberOrigin.y, greaterThan(geometry.center.y));
        }
      }
      final geometry = TerminalSymbolGeometry(sides: _clockwise);
      expect(() => geometry.labelLayout(lineHeight: 0), throwsArgumentError);
      expect(() => geometry.labelLayout(gap: -1), throwsArgumentError);
    },
  );
}
