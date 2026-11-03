// SPDX-License-Identifier: GPL-3.0-or-later
import 'model.dart';
import 'routing.dart';

const _tolerance = 1e-6;

List<Wire> insertCornerIntoWires(Sheet sheet, ConnectionCorner corner) {
  final devices = {for (final d in sheet.devices) d.id: d};
  final markers = {for (final m in sheet.continuations) m.id: m};
  final corners = {for (final c in sheet.corners) c.id: c};
  final result = <Wire>[];
  final pairs = <(WireEndpoint, WireEndpoint)>{
    for (final wire in sheet.wires)
      if (wire.from.ownerId == corner.id)
        (wire.to, wire.from)
      else if (wire.to.ownerId == corner.id)
        (wire.from, wire.to),
  };
  for (final wire in sheet.wires) {
    if (wire.from.ownerId == corner.id || wire.to.ownerId == corner.id) {
      result.add(wire);
      continue;
    }
    final path = WireRouter.path(wire, devices, markers, corners);
    final branches = _branches(path, corner.position);
    if (branches == null) {
      result.add(wire);
      continue;
    }
    var retained = 0;
    for (final (endpoint, branch) in [
      (wire.from, branches.$1),
      (wire.to, branches.$2),
    ]) {
      if (branch.isEmpty) continue;
      final delta = branch.first - corner.position;
      final direction = Vec2(
        delta.x.abs() <= _tolerance ? 0 : delta.x.sign,
        delta.y.abs() <= _tolerance ? 0 : delta.y.sign,
      );
      final port =
          ConnectionCorner.portIds
              .where((id) => corner.direction(id) == direction)
              .firstOrNull;
      if (port == null) continue;
      final distance = delta.distanceTo(Vec2.zero);
      if (distance + _tolerance < ConnectionCorner.armLength ||
          (branch.length > 1 &&
              distance <= ConnectionCorner.armLength + WireRouter.tolerance)) {
        throw const EcadException(
          'The corner arm does not fit before the next endpoint or bend.',
          code: 'corner_clearance',
        );
      }
      final target = CornerRef(cornerId: corner.id, portId: port);
      if (!pairs.add((endpoint, target))) continue;
      // Only the arms drawn by the symbol may carry the previous connection.
      result.add(
        Wire(
          id: retained++ == 0 ? wire.id : newId('wire'),
          from: endpoint,
          to: target,
          waypoints: branch.reversed.skip(1).toList(),
        ),
      );
    }
  }
  return result;
}

(List<Vec2>, List<Vec2>)? _branches(List<Vec2> path, Vec2 at) {
  int? first, last;
  for (var i = 1; i < path.length; i++) {
    final a = path[i - 1], b = path[i];
    final distance = a.distanceTo(b);
    if (distance <= _tolerance) continue;
    final segment = b - a, offset = at - a;
    final across =
        (offset.x * segment.y - offset.y * segment.x).abs() / distance;
    final along = (offset.x * segment.x + offset.y * segment.y) / distance;
    if (across > _tolerance ||
        along < -_tolerance ||
        along > distance + _tolerance) {
      continue;
    }
    if (at.distanceTo(path.first) <= _tolerance ||
        at.distanceTo(path.last) <= _tolerance) {
      return null;
    }
    first ??= i;
    last = i;
  }
  if (first == null) return null;
  // A route may revisit the cut; retain only the branches leading to its ends.
  return (
    path
        .take(first)
        .toList()
        .reversed
        .where((p) => p.distanceTo(at) > _tolerance)
        .toList(),
    path.skip(last!).where((p) => p.distanceTo(at) > _tolerance).toList(),
  );
}
