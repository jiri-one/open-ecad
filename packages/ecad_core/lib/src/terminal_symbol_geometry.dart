// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:math' as math;

import 'model.dart' show PortSide, RectUnits, Vec2;

class TerminalSymbolPort {
  const TerminalSymbolPort({
    required this.localSide,
    required this.side,
    required this.position,
    required this.normal,
  });

  final PortSide localSide;
  final PortSide side;
  final Vec2 position;
  final Vec2 normal;

  // Rotation must not change the key used to bind an existing wire.
  String get key => localSide.name;
}

class TerminalSymbolArm {
  const TerminalSymbolArm({required this.start, required this.port});

  final Vec2 start;
  final TerminalSymbolPort port;
  Vec2 get end => port.position;
}

class TerminalSymbolLabelLayout {
  const TerminalSymbolLabelLayout({
    required this.designationOrigin,
    required this.numberOrigin,
    required this.lineHeight,
  });

  final Vec2 designationOrigin;
  final Vec2 numberOrigin;
  final double lineHeight;
}

class TerminalSymbolGeometry {
  factory TerminalSymbolGeometry({
    required Iterable<PortSide> sides,
    Vec2 center = Vec2.zero,
    double radius = defaultRadius,
    double portDistance = defaultPortDistance,
    int quarterTurns = 0,
  }) {
    final selected = sides.toSet();
    if (selected.isEmpty) {
      throw ArgumentError.value(
        sides,
        'sides',
        'At least one side is required.',
      );
    }
    if (!center.x.isFinite || !center.y.isFinite) {
      throw ArgumentError.value(center, 'center', 'Must be finite.');
    }
    _positive(radius, 'radius');
    _positive(portDistance, 'portDistance');
    if (portDistance <= radius) {
      throw ArgumentError.value(
        portDistance,
        'portDistance',
        'Must exceed the circle radius.',
      );
    }
    final orderedSides = Set<PortSide>.unmodifiable(
      sideOrder.where(selected.contains),
    );
    final turns = quarterTurns % 4;
    final ports = <TerminalSymbolPort>[
      for (final localSide in orderedSides)
        TerminalSymbolPort(
          localSide: localSide,
          side: rotateSide(localSide, turns),
          position:
              center +
              normalForSide(rotateSide(localSide, turns)) * portDistance,
          normal: normalForSide(rotateSide(localSide, turns)),
        ),
    ];
    return TerminalSymbolGeometry._(
      center: center,
      radius: radius,
      portDistance: portDistance,
      quarterTurns: turns,
      sides: orderedSides,
      ports: List.unmodifiable(ports),
      arms: List.unmodifiable([
        for (final port in ports)
          TerminalSymbolArm(start: center + port.normal * radius, port: port),
      ]),
    );
  }

  const TerminalSymbolGeometry._({
    required this.center,
    required this.radius,
    required this.portDistance,
    required this.quarterTurns,
    required this.sides,
    required this.ports,
    required this.arms,
  });

  static const defaultRadius = 4.0;
  // A snapped center keeps every default port on the editor's 10-unit grid.
  static const defaultPortDistance = 10.0;
  static const sideOrder = [
    PortSide.top,
    PortSide.right,
    PortSide.bottom,
    PortSide.left,
  ];

  final Vec2 center;
  final double radius;
  final double portDistance;
  final int quarterTurns;
  final Set<PortSide> sides;
  final List<TerminalSymbolPort> ports;
  final List<TerminalSymbolArm> arms;

  static PortSide rotateSide(PortSide side, int quarterTurns) =>
      sideOrder[(sideOrder.indexOf(side) + quarterTurns) % 4];

  static Vec2 normalForSide(PortSide side) => switch (side) {
    PortSide.top => const Vec2(0, -1),
    PortSide.right => const Vec2(1, 0),
    PortSide.bottom => const Vec2(0, 1),
    PortSide.left => const Vec2(-1, 0),
  };

  RectUnits get bounds {
    var left = center.x - radius;
    var top = center.y - radius;
    var right = center.x + radius;
    var bottom = center.y + radius;
    for (final port in ports) {
      left = math.min(left, port.position.x);
      top = math.min(top, port.position.y);
      right = math.max(right, port.position.x);
      bottom = math.max(bottom, port.position.y);
    }
    return RectUnits(
      x: left,
      y: top,
      width: right - left,
      height: bottom - top,
    );
  }

  TerminalSymbolLabelLayout labelLayout({
    double lineHeight = 12,
    double gap = 4,
  }) {
    _positive(lineHeight, 'lineHeight');
    if (!gap.isFinite || gap < 0) {
      throw ArgumentError.value(gap, 'gap', 'Must be nonnegative and finite.');
    }
    // Upright lines straddle a possible rightward conductor without crossing it.
    final x = center.x + portDistance + gap;
    return TerminalSymbolLabelLayout(
      designationOrigin: Vec2(x, center.y - gap / 2 - lineHeight),
      numberOrigin: Vec2(x, center.y + gap / 2),
      lineHeight: lineHeight,
    );
  }

  bool hitTest(Vec2 point, {double tolerance = 3}) {
    if (!tolerance.isFinite || tolerance < 0) {
      throw ArgumentError.value(
        tolerance,
        'tolerance',
        'Must be nonnegative and finite.',
      );
    }
    if (!point.x.isFinite || !point.y.isFinite) return false;
    if (point.distanceTo(center) <= radius + tolerance) return true;
    for (final arm in arms) {
      final delta = point - arm.start;
      final along = (delta.x * arm.port.normal.x + delta.y * arm.port.normal.y)
          .clamp(0.0, portDistance - radius);
      if (point.distanceTo(arm.start + arm.port.normal * along) <= tolerance) {
        return true;
      }
    }
    return false;
  }

  static void _positive(double value, String name) {
    if (!value.isFinite || value <= 0) {
      throw ArgumentError.value(value, name, 'Must be positive and finite.');
    }
  }
}
