// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:math' as math;

import 'catalog.dart';
import 'model.dart';

/// Axis-aligned area in sheet units.
class RouteBox {
  const RouteBox(this.left, this.top, this.right, this.bottom);
  final double left;
  final double top;
  final double right;
  final double bottom;

  /// Whether an orthogonal segment enters the interior. Running along the
  /// outline is allowed because terminals lie on it.
  bool crosses(Vec2 a, Vec2 b) {
    const e = WireRouter._epsilon;
    if ((a.x - b.x).abs() < e) {
      return a.x > left + e &&
          a.x < right - e &&
          math.max(a.y, b.y) > top + e &&
          math.min(a.y, b.y) < bottom - e;
    }
    return a.y > top + e &&
        a.y < bottom - e &&
        math.max(a.x, b.x) > left + e &&
        math.min(a.x, b.x) < right - e;
  }
}

/// One end of a route. A free point has no direction and no body.
class WireTerminal {
  const WireTerminal(this.point, {this.direction = Vec2.zero, this.body});
  final Vec2 point;

  /// Unit axis vector pointing away from the symbol.
  final Vec2 direction;
  final RouteBox? body;
}

/// Orthogonal wire geometry shared by the editor, its previews and exports,
/// so every view draws the same path for the same document.
///
/// Routes leave and enter terminals along their outward axis and avoid the
/// two connected symbol bodies unless those overlap; other symbols are not
/// obstacles. Geometry never creates connectivity, which comes only from
/// terminal references. Routing is designed for the editor's 90-degree turns;
/// other rotation angles in external documents use best-effort geometry.
abstract final class WireRouter {
  /// Preferred distance from a terminal or symbol body before a turn.
  static const clearance = 10.0;
  static const _epsilon = 0.01;
  static const _grid = 10.0;
  static const _maxBends = 4;

  /// Null for a port the device kind does not define.
  static WireTerminal? terminal(Device device, String portId) {
    final definition = SymbolCatalog.definitionFor(device.kind);
    final port = definition.portById(portId);
    if (port == null) return null;
    final offset = _offset(device, port);
    return WireTerminal(
      device.position + offset,
      direction: _axis(offset),
      body: _body(device, definition),
    );
  }

  /// Empty when an endpoint cannot be resolved.
  static List<Vec2> path(Wire wire, Map<String, Device> devices) {
    final from = devices[wire.from.deviceId];
    final to = devices[wire.to.deviceId];
    final start = from == null ? null : terminal(from, wire.from.portId);
    final end = to == null ? null : terminal(to, wire.to.portId);
    if (start == null || end == null) return const [];
    return route(start, end, wire.waypoints);
  }

  /// Visits [waypoints] in order. A turn that only goes back over the same
  /// line is dropped, so a stale waypoint cannot leave a dangling stub.
  ///
  /// Waypoints that cannot be visited without crossing a connected symbol or
  /// reaching a terminal from the wrong side are ignored: first those inside
  /// a symbol, then all. Only overlapping symbols keep the best-effort path.
  static List<Vec2> route(
    WireTerminal start,
    WireTerminal end, [
    List<Vec2> waypoints = const [],
  ]) {
    final routed = _through(start, end, waypoints);
    if (waypoints.isEmpty || _sound(routed, start, end)) return routed;
    final outside = [
      for (final point in waypoints)
        if (!_inside(start.body, point) && !_inside(end.body, point)) point,
    ];
    for (final hints in [
      if (outside.isNotEmpty && outside.length < waypoints.length) outside,
      const <Vec2>[],
    ]) {
      final retry = _through(start, end, hints);
      if (_sound(retry, start, end)) return retry;
    }
    return routed;
  }

  /// Validity is judged on the joined, simplified path: legs that are each
  /// valid can still merge into a turn that enters a terminal sideways.
  static bool _sound(List<Vec2> path, WireTerminal start, WireTerminal end) =>
      _fits(path, start.direction, end.direction, [
        if (start.body != null) start.body!,
        if (end.body != null) end.body!,
      ]);

  static bool _inside(RouteBox? box, Vec2 point) =>
      box != null &&
      point.x > box.left + _epsilon &&
      point.x < box.right - _epsilon &&
      point.y > box.top + _epsilon &&
      point.y < box.bottom - _epsilon;

  static bool _onPath(Vec2 point, List<Vec2> path) {
    if (path.length == 1) return _near(point, path.single);
    for (var i = 1; i < path.length; i++) {
      final a = path[i - 1];
      final b = path[i];
      final vertical = (a.x - b.x).abs() < _epsilon;
      final across = vertical ? point.x - a.x : point.y - a.y;
      final along = vertical ? point.y : point.x;
      final low = vertical ? math.min(a.y, b.y) : math.min(a.x, b.x);
      final high = vertical ? math.max(a.y, b.y) : math.max(a.x, b.x);
      if (across.abs() < _epsilon &&
          along > low - _epsilon &&
          along < high + _epsilon) {
        return true;
      }
    }
    return false;
  }

  static List<Vec2> _through(
    WireTerminal start,
    WireTerminal end,
    List<Vec2> waypoints,
  ) {
    final bodies = <RouteBox>[
      if (start.body != null) start.body!,
      if (end.body != null) end.body!,
    ];
    // Waypoints on a terminal would hide its direction from the next leg.
    var from = 0;
    var to = waypoints.length;
    while (from < to && _near(waypoints[from], start.point)) {
      from++;
    }
    while (to > from && _near(waypoints[to - 1], end.point)) {
      to--;
    }
    final anchors = [start.point, ...waypoints.sublist(from, to), end.point];
    final points = <Vec2>[start.point];
    var heading = start.direction;
    for (var i = 1; i < anchors.length; i++) {
      final leg = _leg(
        anchors[i - 1],
        anchors[i],
        heading: heading,
        departure: i == 1 ? start.direction : Vec2.zero,
        arrival: i == anchors.length - 1 ? end.direction : Vec2.zero,
        bodies: bodies,
      );
      points.addAll(leg.skip(1));
      final turn = _direction(leg[leg.length - 2], leg.last);
      if (turn != Vec2.zero) heading = turn;
    }
    return List.unmodifiable(_simplify(points));
  }

  /// Adapts manual waypoints after the wire's devices change from [before]
  /// to [after]. A wire whose ends move together is translated. Otherwise
  /// only the bends next to a changed terminal follow it, so the rest of a
  /// manual route, including a shared branch point, stays where it was.
  static Wire follow(
    Wire wire,
    Map<String, Device> before,
    Map<String, Device> after,
  ) {
    if (wire.waypoints.isEmpty) return wire;
    final oldStart = _at(before, wire.from);
    final newStart = _at(after, wire.from);
    final oldEnd = _at(before, wire.to);
    final newEnd = _at(after, wire.to);
    if (oldStart == null ||
        newStart == null ||
        oldEnd == null ||
        newEnd == null) {
      return wire;
    }
    final startChanged = !_same(oldStart, newStart);
    final endChanged = !_same(oldEnd, newEnd);
    if (!startChanged && !endChanged) return wire;
    final original = wire.waypoints;
    final shift = newStart.point - oldStart.point;
    if (startChanged &&
        endChanged &&
        oldStart.direction == newStart.direction &&
        oldEnd.direction == newEnd.direction &&
        _near(shift, newEnd.point - oldEnd.point)) {
      // Translating the symbols with the route keeps it exactly as valid.
      return wire.copyWith(
        waypoints: [for (final point in original) _tidy(point + shift)],
      );
    }
    final points = [...original];
    final forward = List<int>.generate(original.length, (i) => i);
    final backward = forward.reversed.toList();
    final startRun = _run(original, forward, oldStart.point);
    final endRun = _run(original, backward, oldEnd.point);
    final startWritten = <int>{};
    if (startChanged) {
      _drag(
        points,
        original,
        forward,
        startRun,
        oldStart,
        newStart,
        keep: {...endRun.on, ...endRun.line},
        locked: const {},
        written: startWritten,
      );
    }
    if (endChanged) {
      _drag(
        points,
        original,
        backward,
        endRun,
        oldEnd,
        newEnd,
        keep: {...startRun.on, ...startRun.line},
        locked: startWritten,
        written: <int>{},
      );
    }
    // Sliding a bend can put it inside a connected symbol, and the device may
    // land on a far bend. Such hints are dropped, then the moved bends, and
    // finally all of them; the stored route is never knowingly invalid.
    final start = terminal(after[wire.from.deviceId]!, wire.from.portId)!;
    final end = terminal(after[wire.to.deviceId]!, wire.to.portId)!;
    final adjusted = points.map(_tidy).toList();
    final moved = {
      if (startChanged) ...[...startRun.on, ...startRun.line],
      if (endChanged) ...[...endRun.on, ...endRun.line],
    };
    bool clear(Vec2 point) =>
        !_inside(start.body, point) && !_inside(end.body, point);
    var tried = -1;
    for (final hints in [
      adjusted,
      [
        for (final point in adjusted)
          if (clear(point)) point,
      ],
      [
        for (final (index, point) in adjusted.indexed)
          if (!moved.contains(index) && clear(point)) point,
      ],
      const <Vec2>[],
    ]) {
      // Each candidate is a subset of the previous one.
      if (hints.length == tried) continue;
      tried = hints.length;
      final settled = _settle(start, end, hints);
      if (settled != null) return wire.copyWith(waypoints: settled);
    }
    return wire.copyWith(waypoints: adjusted);
  }

  /// [hints] without those the path skips, if the path through them is
  /// sound; a skipped hint would be invisible yet shape later edits.
  static List<Vec2>? _settle(
    WireTerminal start,
    WireTerminal end,
    List<Vec2> hints,
  ) {
    var current = hints;
    for (var attempt = 0; attempt < 4; attempt++) {
      final path = _through(start, end, current);
      if (!_sound(path, start, end)) return null;
      final visited = [
        for (final point in current)
          if (_onPath(point, path)) point,
      ];
      if (visited.length == current.length) return current;
      current = visited;
    }
    return null;
  }

  /// Waypoint indices next to a terminal, in [order] from it: those on the
  /// terminal, then the run sharing its vertical or horizontal line.
  static ({List<int> on, List<int> line, bool vertical}) _run(
    List<Vec2> original,
    List<int> order,
    Vec2 terminal,
  ) {
    var k = 0;
    while (k < order.length && _near(original[order[k]], terminal)) {
      k++;
    }
    final on = order.sublist(0, k);
    if (k == order.length) return (on: on, line: const [], vertical: false);
    final vertical = (original[order[k]].x - terminal.x).abs() < _epsilon;
    final line = <int>[];
    for (; k < order.length; k++) {
      final point = original[order[k]];
      final offset = vertical ? point.x - terminal.x : point.y - terminal.y;
      if (offset.abs() >= _epsilon) break;
      line.add(order[k]);
    }
    return (on: on, line: line, vertical: vertical);
  }

  /// Moves the bends of one terminal's [run]. Waypoints in [keep] shape the
  /// other end, such as a shared branch point, and are not pushed; written
  /// coordinates in [locked] belong to the other end and stay.
  static void _drag(
    List<Vec2> points,
    List<Vec2> original,
    List<int> order,
    ({List<int> on, List<int> line, bool vertical}) run,
    WireTerminal before,
    WireTerminal after, {
    required Set<int> keep,
    required Set<int> locked,
    required Set<int> written,
  }) {
    void place(int index, {double? x, double? y}) {
      final point = points[index];
      points[index] = Vec2(
        x != null && !locked.contains(2 * index) ? x : point.x,
        y != null && !locked.contains(2 * index + 1) ? y : point.y,
      );
      if (x != null) written.add(2 * index);
      if (y != null) written.add(2 * index + 1);
    }

    final shift = after.point - before.point;
    for (final index in run.on) {
      place(
        index,
        x: original[index].x + shift.x,
        y: original[index].y + shift.y,
      );
    }
    final line = run.line;
    if (line.isEmpty) return;
    final vertical = run.vertical;
    // The run on the terminal's line slides sideways with the terminal.
    for (final index in line) {
      if (vertical) {
        place(index, x: after.point.x);
      } else {
        place(index, y: after.point.y);
      }
    }
    final direction = after.direction;
    if (direction == Vec2.zero) return;
    if (vertical ? direction.y == 0 : direction.x == 0) {
      // A run along the symbol's edge would leave the terminal sideways, so
      // it moves out to where the terminal can reach it straight.
      final limit =
          vertical
              ? _outward(after.point.x, direction.x)
              : _outward(after.point.y, direction.y);
      for (final index in line) {
        if (vertical) {
          place(index, x: limit);
        } else {
          place(index, y: limit);
        }
      }
      return;
    }
    final outward = vertical ? direction.y : direction.x;
    final origin = vertical ? after.point.y : after.point.x;
    final limit = _outward(origin, outward);
    bool behind(int index) =>
        ((vertical ? points[index].y : points[index].x) - origin) * outward <
        clearance - _epsilon;
    void push(int index) =>
        vertical ? place(index, y: limit) : place(index, x: limit);
    final corner = line.last;
    for (final index in line) {
      if (index != corner && behind(index)) push(index);
    }
    if (!behind(corner)) return;
    // Turning behind the terminal would run back through its symbol, so the
    // turn and the rest of its track move outward.
    push(corner);
    final track = original[corner];
    for (var j = order.indexOf(corner) + 1; j < order.length; j++) {
      final index = order[j];
      final point = original[index];
      final offset = vertical ? point.y - track.y : point.x - track.x;
      if (keep.contains(index) || offset.abs() >= _epsilon) break;
      push(index);
    }
  }

  static List<Vec2> _leg(
    Vec2 a,
    Vec2 b, {
    required Vec2 heading,
    required Vec2 departure,
    required Vec2 arrival,
    required List<RouteBox> bodies,
  }) {
    if (_near(a, b)) return [a, b];
    final xs = _tracks(a.x, b.x, departure.x, arrival.x, [
      for (final body in bodies) (body.left, body.right),
    ]);
    final ys = _tracks(a.y, b.y, departure.y, arrival.y, [
      for (final body in bodies) (body.top, body.bottom),
    ]);
    // Bodies that cannot be avoided, such as overlapping symbols, still get
    // the terminal directions before the historical single corner.
    for (final avoid in [bodies, if (bodies.isNotEmpty) const <RouteBox>[]]) {
      for (var bends = 0; bends <= _maxBends; bends++) {
        List<Vec2>? best;
        var bestLength = 0.0;
        var bestReverses = false;
        for (final corners in _shapes(a, b, bends, xs, ys)) {
          final candidate = _simplify([a, ...corners, b]);
          if (!_fits(candidate, departure, arrival, avoid)) continue;
          final length = _length(candidate);
          final reverses = _direction(candidate[0], candidate[1]) == -heading;
          if (best == null ||
              length < bestLength - _epsilon ||
              (length < bestLength + _epsilon && bestReverses && !reverses)) {
            best = candidate;
            bestLength = length;
            bestReverses = reverses;
          }
        }
        if (best != null) return best;
      }
    }
    return [a, Vec2(a.x, b.y), b];
  }

  /// Corner sequences with [bends] corners; vertical-first shapes come first
  /// and the grid-aligned midpoint is the first track, as in earlier routes.
  static Iterable<List<Vec2>> _shapes(
    Vec2 a,
    Vec2 b,
    int bends,
    List<double> xs,
    List<double> ys,
  ) sync* {
    switch (bends) {
      case 0:
        yield const [];
      case 1:
        yield [Vec2(a.x, b.y)];
        yield [Vec2(b.x, a.y)];
      case 2:
        for (final y in ys) {
          yield [Vec2(a.x, y), Vec2(b.x, y)];
        }
        for (final x in xs) {
          yield [Vec2(x, a.y), Vec2(x, b.y)];
        }
      case 3:
        for (final y in ys) {
          for (final x in xs) {
            yield [Vec2(a.x, y), Vec2(x, y), Vec2(x, b.y)];
          }
        }
        for (final x in xs) {
          for (final y in ys) {
            yield [Vec2(x, a.y), Vec2(x, y), Vec2(b.x, y)];
          }
        }
      default:
        for (final y1 in ys) {
          for (final x in xs) {
            for (final y2 in ys) {
              yield [Vec2(a.x, y1), Vec2(x, y1), Vec2(x, y2), Vec2(b.x, y2)];
            }
          }
        }
        for (final x1 in xs) {
          for (final y in ys) {
            for (final x2 in xs) {
              yield [Vec2(x1, a.y), Vec2(x1, y), Vec2(x2, y), Vec2(x2, b.y)];
            }
          }
        }
    }
  }

  static List<double> _tracks(
    double a,
    double b,
    double departure,
    double arrival,
    List<(double, double)> spans,
  ) {
    final values = [
      ((a + b) / (2 * _grid)).round() * _grid,
      (a + b) / 2,
      a,
      b,
      if (departure != 0) a + departure * clearance,
      if (arrival != 0) b + arrival * clearance,
      for (final (low, high) in spans) ...[low - clearance, high + clearance],
      // Symbols closer than the clearance still leave a usable gap.
      for (final (_, high) in spans)
        for (final (low, _) in spans)
          if (high <= low) (high + low) / 2,
    ];
    final tracks = <double>[];
    for (final value in values) {
      if (!tracks.any((track) => (track - value).abs() < _epsilon)) {
        tracks.add(value);
      }
    }
    return tracks;
  }

  static bool _fits(
    List<Vec2> path,
    Vec2 departure,
    Vec2 arrival,
    List<RouteBox> bodies,
  ) {
    if (path.length < 2) return true;
    for (var i = 1; i < path.length; i++) {
      if (_direction(path[i - 1], path[i]) == Vec2.zero) return false;
    }
    if (departure != Vec2.zero && _direction(path[0], path[1]) != departure) {
      return false;
    }
    if (arrival != Vec2.zero &&
        _direction(path[path.length - 2], path.last) != -arrival) {
      return false;
    }
    for (var i = 1; i < path.length; i++) {
      for (final body in bodies) {
        if (body.crosses(path[i - 1], path[i])) return false;
      }
    }
    return true;
  }

  /// Removes repeated points, straight-through corners and spikes, keeping
  /// the exact first and last points.
  static List<Vec2> _simplify(List<Vec2> points) {
    final result = <Vec2>[];
    for (final point in points) {
      result.add(point);
      while (true) {
        final n = result.length;
        if (n >= 2 && _near(result[n - 2], result[n - 1])) {
          result.removeAt(n == 2 ? 1 : n - 2);
        } else if (n >= 3 &&
            _collinear(result[n - 3], result[n - 2], result[n - 1])) {
          result.removeAt(n - 2);
        } else {
          break;
        }
      }
    }
    return result;
  }

  static RouteBox? _body(Device device, SymbolDefinition definition) {
    final radians = device.rotation * math.pi / 180;
    final cos = math.cos(radians).abs();
    final sin = math.sin(radians).abs();
    final halfWidth = (definition.width * cos + definition.height * sin) / 2;
    final halfHeight = (definition.width * sin + definition.height * cos) / 2;
    var left = device.position.x - halfWidth;
    var right = device.position.x + halfWidth;
    var top = device.position.y - halfHeight;
    var bottom = device.position.y + halfHeight;
    // A terminal inside the box, as with odd rotations, must remain able to
    // leave it.
    for (final port in definition.ports) {
      final offset = _offset(device, port);
      final point = device.position + offset;
      final axis = _axis(offset);
      if (axis.x > 0) right = math.min(right, point.x);
      if (axis.x < 0) left = math.max(left, point.x);
      if (axis.y > 0) bottom = math.min(bottom, point.y);
      if (axis.y < 0) top = math.max(top, point.y);
    }
    if (right - left < _epsilon || bottom - top < _epsilon) return null;
    return RouteBox(left, top, right, bottom);
  }

  /// Without the body, which following waypoints does not need.
  static WireTerminal? _at(Map<String, Device> devices, TerminalRef ref) {
    final device = devices[ref.deviceId];
    if (device == null) return null;
    final port = SymbolCatalog.definitionFor(device.kind).portById(ref.portId);
    if (port == null) return null;
    final offset = _offset(device, port);
    return WireTerminal(device.position + offset, direction: _axis(offset));
  }

  // Most symbols are unrotated; skipping the trigonometry keeps large batch
  // moves cheap.
  static Vec2 _offset(Device device, PortDefinition port) =>
      device.rotation == 0
          ? port.position
          : port.position.rotated(device.rotation);

  static bool _same(WireTerminal a, WireTerminal b) =>
      _near(a.point, b.point) && a.direction == b.direction;

  static Vec2 _axis(Vec2 offset) {
    if (offset.x.abs() < _epsilon && offset.y.abs() < _epsilon) {
      return Vec2.zero;
    }
    return offset.x.abs() >= offset.y.abs()
        ? Vec2(offset.x.sign, 0)
        : Vec2(0, offset.y.sign);
  }

  static double _outward(double coordinate, double sign) {
    final target = (coordinate + sign * clearance) / _grid;
    return (sign > 0 ? target.ceil() : target.floor()) * _grid;
  }

  static Vec2 _direction(Vec2 a, Vec2 b) {
    final dx = b.x - a.x;
    final dy = b.y - a.y;
    if (dx.abs() < _epsilon && dy.abs() >= _epsilon) return Vec2(0, dy.sign);
    if (dy.abs() < _epsilon && dx.abs() >= _epsilon) return Vec2(dx.sign, 0);
    return Vec2.zero;
  }

  static bool _near(Vec2 a, Vec2 b) =>
      (a.x - b.x).abs() < _epsilon && (a.y - b.y).abs() < _epsilon;

  static bool _collinear(Vec2 a, Vec2 b, Vec2 c) =>
      ((a.x - b.x).abs() < _epsilon && (b.x - c.x).abs() < _epsilon) ||
      ((a.y - b.y).abs() < _epsilon && (b.y - c.y).abs() < _epsilon);

  static double _length(List<Vec2> points) {
    var length = 0.0;
    for (var i = 1; i < points.length; i++) {
      length += points[i].distanceTo(points[i - 1]);
    }
    return length;
  }

  // Rotations leave sub-picometer noise that should not reach the document.
  static Vec2 _tidy(Vec2 point) => Vec2(_round(point.x), _round(point.y));
  static double _round(double value) {
    final rounded = value.roundToDouble();
    return (value - rounded).abs() < 1e-9 ? rounded : value;
  }
}
