// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:math' as math;

import 'graphics.dart';
import 'model.dart';

List<DrawingElement> fitGraphicsToFrame(
  Sheet source,
  Sheet target,
  FrameGeometry geometry, {
  required Set<String> retainedGraphicIds,
}) {
  for (final sheet in [source, target]) {
    if (sheet.devices.isNotEmpty ||
        sheet.wires.isNotEmpty ||
        sheet.corners.isNotEmpty ||
        sheet.continuations.isNotEmpty ||
        sheet.mountingView != null ||
        sheet.report != null ||
        sheet.type == SheetType.billOfMaterials) {
      throw const EcadException(
        'Frame fitting requires graphic-only sheets.',
        code: 'incompatible_sheet_content',
      );
    }
  }
  final content = frameContentUnits(target, geometry);
  final ids = <String>{};
  for (final graphic in source.graphics) {
    if (!ids.add(graphic.id))
      throw const EcadException('Duplicate graphic ID.', code: 'duplicate_id');
  }
  if (!ids.containsAll(retainedGraphicIds)) {
    throw const EcadException(
      'Frame fitting selection contains missing graphics.',
      code: 'missing_graphic',
    );
  }
  final graphics =
      source.graphics.where((g) => retainedGraphicIds.contains(g.id)).toList();
  if (graphics.isEmpty) return const [];
  var left = double.infinity, top = double.infinity;
  var right = double.negativeInfinity, bottom = double.negativeInfinity;
  for (final graphic in graphics) {
    requireValidDrawingElement(graphic);
    final points =
        graphic.kind == DrawingKind.path
            ? graphic.path.expand((segment) => segment.points)
            : [
              Vec2.zero,
              Vec2(graphic.width, 0),
              Vec2(0, graphic.height),
              Vec2(graphic.width, graphic.height),
            ];
    // Control-point hulls and miter allowance keep painted strokes inside the fit.
    final pad = graphic.stroke == null ? 0.0 : graphic.strokeWidth * 5;
    for (final point in points) {
      final p = graphic.position + point.rotated(graphic.rotation);
      left = math.min(left, p.x - pad);
      right = math.max(right, p.x + pad);
      top = math.min(top, p.y - pad);
      bottom = math.max(bottom, p.y + pad);
    }
  }
  if (![left, top, right, bottom].every((v) => v.isFinite) ||
      content.width <= 0 ||
      content.height <= 0) {
    throw const EcadException(
      'No finite artwork or content bounds to fit.',
      code: 'invalid_frame_layout',
    );
  }
  final width = right - left, height = bottom - top;
  final scale =
      width == 0 && height == 0
          ? 1.0
          : math.min(
            width == 0 ? double.infinity : content.width / width,
            height == 0 ? double.infinity : content.height / height,
          );
  final offset =
      Vec2(content.x + content.width / 2, content.y + content.height / 2) -
      Vec2((left + right) / 2, (top + bottom) / 2) * scale;
  return List.unmodifiable(
    graphics.map((g) => transformGraphic(g, scale: scale, offset: offset)),
  );
}

DrawingElement transformGraphic(
  DrawingElement graphic, {
  required double scale,
  required Vec2 offset,
}) {
  if (!scale.isFinite ||
      scale <= 0 ||
      !offset.x.isFinite ||
      !offset.y.isFinite) {
    throw const EcadException(
      'Graphic transform must be finite with positive scale.',
      code: 'invalid_geometry',
    );
  }
  requireValidDrawingElement(graphic);
  final transformed = graphic.copyWith(
    position: graphic.position * scale + offset,
    width: graphic.width * scale,
    height: graphic.height * scale,
    path:
        graphic.path
            .map(
              (s) => PathSegment(
                verb: s.verb,
                points: s.points.map((p) => p * scale).toList(),
              ),
            )
            .toList(),
    strokeWidth: graphic.strokeWidth * scale,
    dash: graphic.dash.map((v) => v * scale).toList(),
    fontSize: graphic.fontSize * scale,
  );
  requireValidDrawingElement(transformed);
  return transformed;
}
