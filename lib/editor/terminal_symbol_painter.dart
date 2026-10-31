// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:math' as math;

import 'package:ecad_core/terminal_symbol_geometry.dart';
import 'package:flutter/material.dart';

void paintTerminalSymbol(
  Canvas canvas,
  TerminalSymbolGeometry geometry, {
  required Color ink,
  Color? paper,
  double strokeWidth = 1.6,
}) {
  assert(strokeWidth.isFinite && strokeWidth >= 0);
  final stroke =
      Paint()
        ..color = ink
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.butt;
  for (final arm in geometry.arms) {
    canvas.drawLine(
      Offset(arm.start.x, arm.start.y),
      Offset(arm.end.x, arm.end.y),
      stroke,
    );
  }
  final center = Offset(geometry.center.x, geometry.center.y);
  if (paper != null) {
    canvas.drawCircle(center, geometry.radius, Paint()..color = paper);
  }
  canvas.drawCircle(center, geometry.radius, stroke);
}

class TerminalSymbolPreviewPainter extends CustomPainter {
  const TerminalSymbolPreviewPainter({
    required this.geometry,
    required this.ink,
    this.paper,
    this.strokeWidth = 1.6,
    this.padding = 6,
  }) : assert(strokeWidth >= 0),
       assert(padding >= 0);

  final TerminalSymbolGeometry geometry;
  final Color ink;
  final Color? paper;
  final double strokeWidth;
  final double padding;

  @override
  void paint(Canvas canvas, Size size) {
    final available = math.min(size.width, size.height) - padding * 2;
    if (available <= 0) return;
    // A fixed envelope keeps the circle still while individual arms toggle.
    final scale = available / (2 * geometry.portDistance + strokeWidth);
    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.scale(scale);
    canvas.translate(-geometry.center.x, -geometry.center.y);
    paintTerminalSymbol(
      canvas,
      geometry,
      ink: ink,
      paper: paper,
      strokeWidth: strokeWidth,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant TerminalSymbolPreviewPainter oldDelegate) =>
      geometry != oldDelegate.geometry ||
      ink != oldDelegate.ink ||
      paper != oldDelegate.paper ||
      strokeWidth != oldDelegate.strokeWidth ||
      padding != oldDelegate.padding;
}

class TerminalSymbolPreview extends StatelessWidget {
  const TerminalSymbolPreview({
    super.key,
    required this.geometry,
    this.size = const Size(72, 72),
    this.ink,
    this.paper,
    this.strokeWidth = 1.6,
    this.padding = 6,
    this.semanticLabel,
  });

  final TerminalSymbolGeometry geometry;
  final Size size;
  final Color? ink;
  final Color? paper;
  final double strokeWidth;
  final double padding;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final preview = CustomPaint(
      size: size,
      painter: TerminalSymbolPreviewPainter(
        geometry: geometry,
        ink: ink ?? Theme.of(context).colorScheme.onSurface,
        paper: paper,
        strokeWidth: strokeWidth,
        padding: padding,
      ),
    );
    return semanticLabel == null
        ? preview
        : Semantics(image: true, label: semanticLabel, child: preview);
  }
}
