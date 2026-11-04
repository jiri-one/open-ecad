// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/painting.dart';

import 'report_layout.dart';

class PortAnnotation {
  const PortAnnotation(this.port, this.text, this.bounds);
  final ResolvedPort port;
  final String text;
  final Rect bounds;
}

class DeviceCrossReference {
  const DeviceCrossReference(
    this.sourceId,
    this.target,
    this.text,
    this.bounds,
    this.baseline,
  );
  final String sourceId;
  final DeviceOccurrence target;
  final String text;
  final Rect bounds;
  final double baseline;
}

List<DeviceCrossReference> layoutDeviceCrossReferences(
  ProjectResolver resolver,
  Device device,
) {
  final targets = resolver.otherOccurrences(device);
  if (targets.isEmpty) return const [];
  final geometry = geometryFor(device);
  final bounds = rotatedBounds(
    device.position,
    geometry.width,
    geometry.height,
    device.rotation,
  );
  final terminal =
      device.symbol is TerminalSymbolSpec
          ? TerminalSymbolGeometry(
            sides: (device.symbol as TerminalSymbolSpec).sides,
            center: device.position,
            quarterTurns: device.rotation ~/ 90,
          ).labelLayout()
          : null;
  var x = terminal?.designationOrigin.x ?? bounds.x + bounds.width + 18;
  if (terminal == null) {
    for (final port in layoutPortAnnotations(resolver, device)) {
      if (port.bounds.right + 12 > x) x = port.bounds.right + 12;
    }
  }
  var y = (terminal?.numberOrigin.y ?? device.position.y + 1) + 14;
  final result = <DeviceCrossReference>[];
  for (final target in targets) {
    final point = target.device.position;
    final text =
        '${fullPageDesignation(target.sheet)}${resolver.isMainFunction(target.device) ? ' (H)' : ''} · ${point.x.toStringAsFixed(1)}/${point.y.toStringAsFixed(1)}';
    final painter = reportTextPainter(text, 8.5);
    final rect = Rect.fromLTWH(x, y, painter.width, painter.height);
    final baseline = y + painter.computeLineMetrics().first.baseline;
    painter.dispose();
    y = rect.bottom + 3;
    result.add(DeviceCrossReference(device.id, target, text, rect, baseline));
  }
  return List.unmodifiable(result);
}

List<PortAnnotation> layoutPortAnnotations(
  ProjectResolver resolver,
  Device device,
) {
  if (device.symbol is TerminalSymbolSpec) return const [];
  final result = <PortAnnotation>[];
  for (final port in resolver.ports(device)) {
    final label = [
      port.label,
      port.signal,
    ].where((s) => s.isNotEmpty).join(' · ');
    final painter = reportTextPainter(label, 9)..layout(maxWidth: 180);
    final lines = [
      for (final line in painter.computeLineMetrics())
        painter.getLineBoundary(
          painter.getPositionForOffset(
            Offset(0, line.baseline - line.ascent / 2),
          ),
        ),
    ];
    final wrapped = lines
        .map((line) => label.substring(line.start, line.end).trim())
        .join('\n');
    final width = painter.width + 4;
    final height = painter.height + 2;
    painter.dispose();
    final p = port.geometry.point;
    final n = port.geometry.direction;
    var rect = Rect.fromLTWH(
      n.x < 0
          ? p.x - width - 6
          : n.x > 0
          ? p.x + 6
          : p.x + 4,
      n.y < 0
          ? p.y - height - 4
          : n.y > 0
          ? p.y + 4
          : p.y - height - 3,
      width,
      height,
    );
    // Stagger dense adjacent pins without rotating their readable labels.
    while (result.any((r) => r.bounds.inflate(2).overlaps(rect))) {
      rect = rect.shift(Offset(0, n.y > 0 ? height + 3 : -height - 3));
    }
    result.add(PortAnnotation(port, wrapped, rect));
  }
  return List.unmodifiable(result);
}
