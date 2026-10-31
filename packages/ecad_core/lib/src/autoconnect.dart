// SPDX-License-Identifier: GPL-3.0-or-later
import 'catalog.dart';
import 'model.dart';
import 'routing.dart';

/// Derived from one immutable sheet; no identity or geometry is shared between documents.
abstract final class AutoConnect {
  static const tolerance = 1e-6;

  static List<Wire> wires(Sheet sheet) =>
      List.unmodifiable([...sheet.wires, ...automaticWires(sheet)]);

  static List<Wire> automaticWires(Sheet sheet) {
    if (sheet.type != SheetType.multiLine &&
        sheet.type != SheetType.singleLine) {
      return const [];
    }
    final ports = <({WireEndpoint ref, WireTerminal terminal})>[
      for (final device in sheet.devices)
        if (device.mode == OccurrenceMode.wiring)
          for (final port in geometryFor(device).ports)
            (
              ref: TerminalRef(deviceId: device.id, portId: port.id),
              terminal: WireRouter.terminal(device, port.id)!,
            ),
      for (final marker in sheet.continuations)
        (
          ref: ContinuationRef(markerId: marker.id),
          terminal: WireTerminal(
            marker.position,
            direction: sideDirection(marker.direction),
          ),
        ),
      for (final corner in sheet.corners)
        for (final port in ConnectionCorner.portIds)
          (
            ref: CornerRef(cornerId: corner.id, portId: port),
            terminal: WireTerminal(
              corner.portPosition(port)!,
              direction: corner.direction(port)!,
            ),
          ),
    ];
    final occupied = {
      for (final w in sheet.wires) ...[w.from, w.to],
    };
    final bodies = {
      for (final device in sheet.devices) device.id: WireRouter.body(device),
    };
    for (final corner in sheet.corners) {
      final path = corner.path;
      if (bodies.values.any(
        (body) =>
            body.crosses(path[0], path[1]) || body.crosses(path[1], path[2]),
      )) {
        occupied.addAll([
          for (final port in ConnectionCorner.portIds)
            CornerRef(cornerId: corner.id, portId: port),
        ]);
      }
    }
    final result = <Wire>[];
    for (final horizontal in [true, false]) {
      double across(WireTerminal t) => horizontal ? t.point.y : t.point.x;
      double along(WireTerminal t) => horizontal ? t.point.x : t.point.y;
      final sorted = [...ports]
        ..sort((a, b) => across(a.terminal).compareTo(across(b.terminal)));
      var start = 0;
      while (start < sorted.length) {
        var end = start + 1;
        while (end < sorted.length &&
            (across(sorted[end].terminal) - across(sorted[start].terminal))
                    .abs() <=
                tolerance) {
          end++;
        }
        final line = sorted.sublist(start, end)
          ..sort((a, b) => along(a.terminal).compareTo(along(b.terminal)));
        for (var i = 1; i < line.length; i++) {
          var a = line[i - 1];
          var b = line[i];
          // Ambiguous coincident ports and occupied ports stop the ray; never skip them.
          if ((i > 1 &&
                  along(a.terminal) - along(line[i - 2].terminal) <=
                      tolerance) ||
              (i + 1 < line.length &&
                  along(line[i + 1].terminal) - along(b.terminal) <=
                      tolerance) ||
              occupied.contains(a.ref) ||
              occupied.contains(b.ref) ||
              a.ref.ownerId == b.ref.ownerId)
            continue;
          final direction = horizontal ? const Vec2(1, 0) : const Vec2(0, 1);
          if ((along(b.terminal) - along(a.terminal)).abs() <= tolerance &&
              a.terminal.direction.distanceTo(-direction) <= tolerance) {
            final previous = a;
            a = b;
            b = previous;
          }
          if (a.terminal.direction.distanceTo(direction) > tolerance ||
              b.terminal.direction.distanceTo(-direction) > tolerance)
            continue;
          if (bodies.entries.any((entry) {
            final body =
                entry.key == a.ref.ownerId
                    ? a.terminal.body
                    : entry.key == b.ref.ownerId
                    ? b.terminal.body
                    : entry.value;
            return body?.crosses(a.terminal.point, b.terminal.point) ?? false;
          }))
            continue;
          result.add(_AutomaticWire(a.ref, b.ref));
        }
        start = end;
      }
    }
    return List.unmodifiable(result);
  }
}

class _AutomaticWire extends Wire {
  _AutomaticWire(WireEndpoint from, WireEndpoint to)
    : super(id: '@auto:${_key(from)}>${_key(to)}', from: from, to: to);
  @override
  bool get isAutomatic => true;
  static String _key(WireEndpoint endpoint) => switch (endpoint) {
    TerminalRef(:final deviceId, :final portId) =>
      's:${deviceId.length}:$deviceId:$portId',
    ContinuationRef(:final markerId) => 'm:$markerId',
    CornerRef(:final cornerId, :final portId) =>
      'c:${cornerId.length}:$cornerId:$portId',
  };
}
