import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/material.dart';

import 'spatial_index.dart';

/// Retained geometry for one editable drawing object. PDF page frames are
/// tested against their strokes rather than their large, mostly empty bounds.
class DrawingVisual {
  DrawingVisual(this.element) {
    if (element.kind == DrawingKind.path) {
      path = _makePath(element.path)
        ..fillType =
            element.evenOdd ? PathFillType.evenOdd : PathFillType.nonZero;
      _strokeSegments = _flatten(element.path);
    }
    bounds = _worldBounds(element, path?.getBounds());
  }

  final DrawingElement element;
  late final Rect bounds;
  Path? path;
  List<(Offset, Offset)> _strokeSegments = const [];
  TextPainter? _textPainter;
  Color? _textColor;

  bool hitTest(Offset point, double tolerance) {
    if (element.opacity == 0) return false;
    final relative = point - Offset(element.position.x, element.position.y);
    final angle = -element.rotation * math.pi / 180;
    final local = Offset(
      relative.dx * math.cos(angle) - relative.dy * math.sin(angle),
      relative.dx * math.sin(angle) + relative.dy * math.cos(angle),
    );
    if (element.kind != DrawingKind.path) {
      return Rect.fromLTWH(
        0,
        0,
        element.width,
        element.height,
      ).inflate(tolerance).contains(local);
    }
    if (element.fill != null && path!.contains(local)) return true;
    if (element.stroke == null) return false;
    final radius = tolerance + element.strokeWidth / 2;
    return _strokeSegments.any(
      (line) => distanceToSegment(local, line.$1, line.$2) <= radius,
    );
  }

  bool intersects(Rect area) {
    if (element.opacity == 0 || !bounds.overlaps(area)) return false;
    if (element.kind != DrawingKind.path) return true;
    if (element.fill != null &&
        [
          area.center,
          area.topLeft,
          area.topRight,
          area.bottomLeft,
          area.bottomRight,
        ].any((point) => hitTest(point, 0))) {
      return true;
    }
    if (element.stroke == null && element.fill == null) return false;
    final angle = element.rotation * math.pi / 180;
    Offset world(Offset point) => Offset(
      element.position.x +
          point.dx * math.cos(angle) -
          point.dy * math.sin(angle),
      element.position.y +
          point.dx * math.sin(angle) +
          point.dy * math.cos(angle),
    );
    final expanded = area.inflate(element.strokeWidth / 2);
    return _strokeSegments.any(
      (line) => _segmentIntersects(world(line.$1), world(line.$2), expanded),
    );
  }

  static bool _segmentIntersects(Offset a, Offset b, Rect area) {
    var minimum = 0.0;
    var maximum = 1.0;
    final delta = b - a;
    for (final (direction, distance) in [
      (-delta.dx, a.dx - area.left),
      (delta.dx, area.right - a.dx),
      (-delta.dy, a.dy - area.top),
      (delta.dy, area.bottom - a.dy),
    ]) {
      if (direction == 0) {
        if (distance < 0) return false;
        continue;
      }
      final fraction = distance / direction;
      if (direction < 0) {
        minimum = math.max(minimum, fraction);
      } else {
        maximum = math.min(maximum, fraction);
      }
      if (minimum > maximum) return false;
    }
    return true;
  }

  void paint(
    Canvas canvas, {
    required Color ink,
    required Color paper,
    bool highContrast = false,
    double displayScale = 1,
    Vec2? position,
    ui.Image? image,
  }) {
    if (element.opacity == 0) return;
    final origin = position ?? element.position;
    canvas.save();
    canvas.translate(origin.x, origin.y);
    canvas.rotate(element.rotation * math.pi / 180);
    Color color(String value) {
      final source = Color(
        int.parse(value.substring(1), radix: 16) | 0xff000000,
      );
      final mapped =
          highContrast
              ? (source.computeLuminance() > .65 ? paper : ink)
              : source;
      return mapped.withValues(alpha: element.opacity);
    }

    switch (element.kind) {
      case DrawingKind.path:
        if (element.fill != null) {
          canvas.drawPath(path!, Paint()..color = color(element.fill!));
        }
        if (element.stroke != null) {
          final paint =
              Paint()
                ..color = color(element.stroke!)
                ..style = PaintingStyle.stroke
                // PDF viewers enhance subpixel strokes to visible hairlines.
                // Keep the exact document width in storage and vector exports;
                // Flutter needs an explicit hairline for the same screen detail.
                ..strokeWidth =
                    element.strokeWidth * displayScale < .5
                        ? 0
                        : element.strokeWidth
                ..strokeCap = StrokeCap.values[element.lineCap]
                ..strokeJoin = StrokeJoin.values[element.lineJoin];
          if (element.dash.isEmpty) {
            canvas.drawPath(path!, paint);
          } else {
            _paintDashed(canvas, path!, paint, element.dash);
          }
        }
      case DrawingKind.text:
        final textColor = color(element.fill ?? element.stroke ?? '#000000');
        if (_textPainter == null || textColor != _textColor) {
          _textPainter?.dispose();
          _textColor = textColor;
          _textPainter = TextPainter(
            text: TextSpan(
              text: element.text,
              style: TextStyle(
                fontFamily: 'NotoSans',
                fontSize: element.fontSize,
                fontWeight: element.bold ? FontWeight.w600 : FontWeight.w400,
                color: textColor,
                // PDF texttrace boxes use one em for their height. Using the
                // font's extra line leading here would shrink every glyph.
                height: 1,
                leadingDistribution: TextLeadingDistribution.proportional,
              ),
            ),
            textDirection: TextDirection.ltr,
          )..layout();
        }
        final layout = _textPainter!;
        if (layout.width > 0 && layout.height > 0) {
          canvas.scale(
            element.width / layout.width,
            element.height / layout.height,
          );
          layout.paint(canvas, Offset.zero);
        }
      case DrawingKind.image:
        final destination = Rect.fromLTWH(0, 0, element.width, element.height);
        if (image != null) {
          canvas.drawImageRect(
            image,
            Rect.fromLTWH(
              0,
              0,
              image.width.toDouble(),
              image.height.toDouble(),
            ),
            destination,
            Paint()
              ..color = Colors.white.withValues(alpha: element.opacity)
              ..filterQuality = FilterQuality.medium,
          );
        } else {
          // The placeholder remains selectable while decoding, or for damaged
          // image data. It is never written into the document or an export.
          canvas.drawRect(
            destination,
            Paint()
              ..color = ink.withValues(alpha: .3)
              ..style = PaintingStyle.stroke
              ..strokeWidth = .5,
          );
          canvas.drawLine(
            destination.topLeft,
            destination.bottomRight,
            Paint()..color = ink.withValues(alpha: .15),
          );
        }
    }
    canvas.restore();
  }

  void dispose() => _textPainter?.dispose();

  static Path _makePath(List<PathSegment> segments) {
    final result = Path();
    for (final segment in segments) {
      final points = segment.points;
      switch (segment.verb) {
        case PathVerb.moveTo:
          result.moveTo(points[0].x, points[0].y);
        case PathVerb.lineTo:
          result.lineTo(points[0].x, points[0].y);
        case PathVerb.cubicTo:
          result.cubicTo(
            points[0].x,
            points[0].y,
            points[1].x,
            points[1].y,
            points[2].x,
            points[2].y,
          );
        case PathVerb.close:
          result.close();
      }
    }
    return result;
  }

  static Rect _worldBounds(DrawingElement element, Rect? pathBounds) {
    final angle = element.rotation * math.pi / 180;
    final cosine = math.cos(angle);
    final sine = math.sin(angle);
    Offset transform(double x, double y) => Offset(
      element.position.x + x * cosine - y * sine,
      element.position.y + x * sine + y * cosine,
    );
    final local =
        pathBounds ?? Rect.fromLTWH(0, 0, element.width, element.height);
    final corners = [
      transform(local.left, local.top),
      transform(local.right, local.top),
      transform(local.left, local.bottom),
      transform(local.right, local.bottom),
    ];
    var result = Rect.fromPoints(corners.first, corners.last);
    for (final corner in corners) {
      result = result.expandToInclude(Rect.fromPoints(corner, corner));
    }
    return result.inflate(math.max(.5, element.strokeWidth / 2));
  }

  static List<(Offset, Offset)> _flatten(List<PathSegment> segments) {
    final result = <(Offset, Offset)>[];
    var current = Offset.zero;
    var start = Offset.zero;
    Offset offset(Vec2 point) => Offset(point.x, point.y);
    void cubic(Offset a, Offset b, Offset c, Offset d, int depth) {
      if (depth >= 10 ||
          (distanceToSegment(b, a, d) <= .4 &&
              distanceToSegment(c, a, d) <= .4)) {
        result.add((a, d));
        return;
      }
      final ab = (a + b) / 2;
      final bc = (b + c) / 2;
      final cd = (c + d) / 2;
      final abc = (ab + bc) / 2;
      final bcd = (bc + cd) / 2;
      final midpoint = (abc + bcd) / 2;
      cubic(a, ab, abc, midpoint, depth + 1);
      cubic(midpoint, bcd, cd, d, depth + 1);
    }

    for (final segment in segments) {
      switch (segment.verb) {
        case PathVerb.moveTo:
          current = start = offset(segment.points[0]);
        case PathVerb.lineTo:
          final next = offset(segment.points[0]);
          result.add((current, next));
          current = next;
        case PathVerb.cubicTo:
          final next = offset(segment.points[2]);
          cubic(
            current,
            offset(segment.points[0]),
            offset(segment.points[1]),
            next,
            0,
          );
          current = next;
        case PathVerb.close:
          result.add((current, start));
          current = start;
      }
    }
    return result;
  }

  static void _paintDashed(
    Canvas canvas,
    Path path,
    Paint paint,
    List<double> dash,
  ) {
    final pattern = dash.length.isOdd ? [...dash, ...dash] : dash;
    if (pattern.every((length) => length <= 0)) {
      canvas.drawPath(path, paint);
      return;
    }
    for (final metric in path.computeMetrics()) {
      var position = 0.0;
      var index = 0;
      while (position < metric.length) {
        final length = pattern[index % pattern.length];
        final end = math.min(position + length, metric.length);
        if (index.isEven && end > position) {
          canvas.drawPath(metric.extractPath(position, end), paint);
        }
        position = end;
        index++;
      }
    }
  }
}

/// Keeps decoded PNGs only for the active sheet and releases native resources
/// when a page changes. A late decoder cannot resurrect an obsolete image.
class DrawingImageCache extends ChangeNotifier {
  final Map<String, ui.Image> _images = {};
  final Set<String> _pending = {};
  final Set<String> _failed = {};
  Set<String> _wanted = {};
  bool _disposed = false;

  ui.Image? imageFor(DrawingElement element) => _images[element.imageData];

  void update(Iterable<DrawingElement> elements) {
    _wanted = {
      for (final element in elements)
        if (element.kind == DrawingKind.image) element.imageData,
    };
    for (final key
        in _images.keys.where((key) => !_wanted.contains(key)).toList()) {
      _images.remove(key)!.dispose();
    }
    _failed.removeWhere((key) => !_wanted.contains(key));
    for (final data in _wanted) {
      if (!_images.containsKey(data) &&
          !_pending.contains(data) &&
          !_failed.contains(data)) {
        _decode(data);
      }
    }
  }

  Future<void> _decode(String data) async {
    _pending.add(data);
    try {
      final codec = await ui.instantiateImageCodec(base64Decode(data));
      late ui.Image image;
      try {
        image = (await codec.getNextFrame()).image;
      } finally {
        codec.dispose();
      }
      if (_disposed || !_wanted.contains(data)) {
        image.dispose();
      } else {
        _images[data] = image;
        notifyListeners();
      }
    } catch (_) {
      if (!_disposed && _wanted.contains(data)) _failed.add(data);
    } finally {
      _pending.remove(data);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    for (final image in _images.values) {
      image.dispose();
    }
    _images.clear();
    _wanted.clear();
    super.dispose();
  }
}
