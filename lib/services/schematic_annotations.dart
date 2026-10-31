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
