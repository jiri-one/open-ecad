// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:math' as math;
import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/painting.dart';
import 'report_layout.dart';

const mountingLabelSize = 10.0;
const mountingCaptionGap = 16.0;
const mountingCaptionSize = 11.0;

RectUnits defaultMountingViewport(
  EcadProject project,
  Sheet sheet, {
  bool surfaceDimensions = true,
}) {
  final content = frameContentUnits(
    sheet,
    layoutFrameGeometry(sheet.paperSizeMm, resolveSheetFrame(project, sheet)),
  );
  if (!surfaceDimensions) return content;
  final painter = reportTextPainter('Plocha 0 × 0 mm', mountingCaptionSize);
  final reserved = mountingCaptionGap + painter.height + 2;
  painter.dispose();
  return RectUnits(
    x: content.x,
    y: content.y,
    width: content.width,
    height: math.max(1, content.height - reserved),
  );
}

String mountingSurfaceCaption(MountingLayout layout) =>
    'Plocha ${layout.widthMm.toString().replaceAll('.', ',')} × ${layout.heightMm.toString().replaceAll('.', ',')} mm';

class MountingAnnotation {
  const MountingAnnotation({
    required this.placementId,
    required this.text,
    required this.bounds,
    required this.textSize,
    required this.baseline,
    required this.rotated,
    this.leaderStart,
    this.leaderEnd,
  });
  final String placementId, text;
  final Rect bounds;
  final Size textSize;
  final double baseline;
  final bool rotated;
  final Offset? leaderStart, leaderEnd;

  Offset get textOrigin => rotated ? bounds.bottomLeft : bounds.topLeft;
}

List<MountingAnnotation> layoutMountingAnnotations(
  ProjectResolver resolver,
  Sheet sheet, {
  List<MountingPlacement>? placements,
}) {
  final view = sheet.mountingView!;
  final transform = MountingTransform(sheet, view);
  final items = placements ?? resolver.layouts[view.layoutId]!.placements;
  final viewport = Rect.fromLTWH(
    view.viewport.x,
    view.viewport.y,
    view.viewport.width,
    view.viewport.height,
  );
  final bodies = <String, Rect>{};
  for (final p in items) {
    final b = resolver.mountingBounds(p)!;
    final at = transform.toSheet(b.topLeft);
    bodies[p.id] = Rect.fromLTWH(
      at.x,
      at.y,
      b.width * transform.unitsPerMm,
      b.height * transform.unitsPerMm,
    );
  }
  final result = <MountingAnnotation>[];
  final pending =
      <
        ({MountingPlacement placement, String text, Size size, double baseline})
      >[];
  for (final p in items) {
    final body = bodies[p.id]!;
    if (!body.overlaps(viewport)) continue;
    final text = resolver.fullDesignation(resolver.components[p.componentId]!);
    final painter = reportTextPainter(text, mountingLabelSize, bold: true);
    final size = painter.size;
    final baseline = painter.computeDistanceToActualBaseline(
      TextBaseline.alphabetic,
    );
    painter.dispose();
    final inner = body.deflate(2);
    final rotated =
        size.width > inner.width &&
        size.width <= inner.height &&
        size.height <= inner.width;
    final bounds = Rect.fromCenter(
      center: body.center,
      width: rotated ? size.height : size.width,
      height: rotated ? size.width : size.height,
    );
    if (inner.contains(bounds.topLeft) && inner.contains(bounds.bottomRight)) {
      result.add(
        MountingAnnotation(
          placementId: p.id,
          text: text,
          bounds: bounds,
          textSize: size,
          baseline: baseline,
          rotated: rotated,
        ),
      );
    } else {
      pending.add((placement: p, text: text, size: size, baseline: baseline));
    }
  }
  for (final item in pending) {
    final body = bodies[item.placement.id]!;
    // Vertical callouts keep long names readable at a dense terminal pitch.
    final rotated = body.height > body.width;
    final width = rotated ? item.size.height : item.size.width;
    final height = rotated ? item.size.width : item.size.height;
    Rect? chosen;
    bool available(Rect box) =>
        viewport.contains(box.topLeft) &&
        viewport.contains(box.bottomRight) &&
        !bodies.values.any((b) => b.overlaps(box.inflate(2))) &&
        !result.any((a) => a.bounds.overlaps(box.inflate(2)));
    for (
      var tier = 0;
      tier <= (viewport.height / (height + 4)).ceil();
      tier++
    ) {
      for (final above in [true, false]) {
        final box = Rect.fromLTWH(
          body.center.dx - width / 2,
          above
              ? body.top - 5 - height - tier * (height + 4)
              : body.bottom + 5 + tier * (height + 4),
          width,
          height,
        );
        if (available(box)) {
          chosen = box;
          break;
        }
      }
      if (chosen != null) break;
    }
    // A cropped edge can leave no room along the body's column.
    if (chosen == null) {
      double bestDistance = double.infinity;
      for (
        var y = viewport.top + 2;
        y + height <= viewport.bottom;
        y += height + 4
      ) {
        for (
          var x = viewport.left + 2;
          x + width <= viewport.right;
          x += width + 4
        ) {
          final box = Rect.fromLTWH(x, y, width, height);
          final distance = (box.center - body.center).distanceSquared;
          if (distance < bestDistance && available(box)) {
            chosen = box;
            bestDistance = distance;
          }
        }
      }
    }
    final bounds =
        chosen ??
        Rect.fromLTWH(
          body.center.dx - width / 2,
          body.top - height - 5,
          width,
          height,
        );
    final above = bounds.center.dy < body.center.dy;
    result.add(
      MountingAnnotation(
        placementId: item.placement.id,
        text: item.text,
        bounds: bounds,
        textSize: item.size,
        baseline: item.baseline,
        rotated: rotated,
        leaderStart: above ? body.topCenter : body.bottomCenter,
        leaderEnd: above ? bounds.bottomCenter : bounds.topCenter,
      ),
    );
  }
  return List.unmodifiable(result);
}

void paintMountingAnnotations(
  Canvas canvas,
  List<MountingAnnotation> annotations, {
  String? activePlacementId,
  Color ink = reportInk,
  Color paper = const Color(0xffffffff),
  Color muted = reportMuted,
}) {
  final leader =
      Paint()
        ..color = muted
        ..strokeWidth = .7;
  for (final a in annotations) {
    if (a.leaderStart != null) {
      canvas.drawLine(a.leaderStart!, a.leaderEnd!, leader);
    }
  }
  for (final a in annotations) {
    if (a.leaderStart != null) {
      canvas.drawRect(a.bounds.inflate(1), Paint()..color = paper);
    }
    canvas.save();
    canvas.translate(a.textOrigin.dx, a.textOrigin.dy);
    if (a.rotated) canvas.rotate(-math.pi / 2);
    final painter = reportTextPainter(a.text, mountingLabelSize, bold: true);
    painter.text = TextSpan(
      text: a.text,
      style: (painter.text! as TextSpan).style!.copyWith(
        decoration:
            a.placementId == activePlacementId
                ? TextDecoration.underline
                : null,
        color:
            a.placementId == activePlacementId ? const Color(0xff1976d2) : ink,
      ),
    );
    painter.layout();
    painter.paint(canvas, Offset.zero);
    painter.dispose();
    canvas.restore();
  }
}
