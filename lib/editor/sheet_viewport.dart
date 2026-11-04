import 'dart:math' as math;

import 'package:flutter/widgets.dart';

double sheetFitScale(Size viewport, Size sheet) {
  if (viewport.isEmpty || sheet.isEmpty) return 1;
  final gutter = math.min(8.0, viewport.shortestSide / 4);
  return math.min(
    (viewport.width - gutter * 2) / sheet.width,
    (viewport.height - gutter * 2) / sheet.height,
  );
}

class SheetViewportController extends TransformationController {
  Size _viewport = Size.zero;
  Size _sheet = Size.zero;
  double _scale = 1;
  bool _layingOut = false;

  bool get layingOut => _layingOut;

  double layout(Size viewport, Size sheet) {
    _layingOut = true;
    try {
      if (_sheet != sheet) {
        value = Matrix4.identity();
      }
      if (value.isIdentity()) {
        _scale = sheetFitScale(viewport, sheet);
      } else if (_viewport != viewport) {
        // Keep the same world point at the center after manual navigation.
        final delta =
            (viewport.center(Offset.zero) - _viewport.center(Offset.zero)) *
            (1 - value.getMaxScaleOnAxis());
        final translation = value.getTranslation();
        value =
            value.clone()..setTranslationRaw(
              translation.x + delta.dx,
              translation.y + delta.dy,
              translation.z,
            );
      }
      _viewport = viewport;
      _sheet = sheet;
      return _scale;
    } finally {
      _layingOut = false;
    }
  }
}
