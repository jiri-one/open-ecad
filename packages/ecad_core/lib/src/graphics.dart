// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'dart:typed_data';

import 'model.dart';

/// Drawing geometry carries no inferred electrical connectivity.
enum DrawingKind { path, text, image }

enum PathVerb {
  moveTo('M', 1),
  lineTo('L', 1),
  cubicTo('C', 3),
  close('Z', 0);

  const PathVerb(this.code, this.pointCount);
  final String code;
  final int pointCount;
}

class PathSegment {
  PathSegment({required this.verb, List<Vec2> points = const []})
    : points = List.unmodifiable(points);

  final PathVerb verb;
  final List<Vec2> points;

  Map<String, Object?> toJson() => {
    'verb': verb.code,
    if (points.isNotEmpty) 'points': points.map((p) => p.toJson()).toList(),
  };

  factory PathSegment.fromJson(Object? value) {
    final map = jsonObject(
      value,
      'path segment',
      allowed: const {'verb', 'points'},
    );
    final code = jsonString(map, 'verb', max: 1);
    final matches = PathVerb.values.where((verb) => verb.code == code);
    if (matches.isEmpty) {
      throw EcadException('Unknown path verb "$code".', code: 'invalid_schema');
    }
    final verb = matches.first;
    final points =
        jsonList(
          map,
          'points',
          max: 3,
          optional: verb == PathVerb.close,
        ).map(Vec2.fromJson).toList();
    if (points.length != verb.pointCount) {
      throw EcadException(
        'Path verb ${verb.code} requires ${verb.pointCount} points.',
        code: 'invalid_geometry',
      );
    }
    return PathSegment(verb: verb, points: points);
  }
}

const _unchanged = Object();

/// Native editable geometry in sheet units, with a top-left local origin.
/// Rotation is clockwise on screen around [position], not the bounds center.
/// Images contain raw base64 PNG bytes; references to external files or URLs
/// are deliberately absent from the portable document format.
class DrawingElement {
  DrawingElement({
    required this.id,
    required this.kind,
    required this.position,
    required this.width,
    required this.height,
    this.rotation = 0,
    List<PathSegment> path = const [],
    this.stroke,
    this.fill,
    this.strokeWidth = 1,
    this.lineCap = 0,
    this.lineJoin = 0,
    this.evenOdd = false,
    this.opacity = 1,
    List<double> dash = const [],
    this.text = '',
    this.fontSize = 12,
    this.bold = false,
    this.imageData = '',
  }) : path = List.unmodifiable(path),
       dash = List.unmodifiable(dash);

  final String id;
  final DrawingKind kind;
  final Vec2 position;
  final double width;
  final double height;
  final double rotation;
  final List<PathSegment> path;
  final String? stroke;
  final String? fill;
  final double strokeWidth;
  final int lineCap;
  final int lineJoin;
  final bool evenOdd;
  final double opacity;
  final List<double> dash;
  final String text;
  final double fontSize;
  final bool bold;
  final String imageData;

  // Elements and their nested geometry are immutable. Reusing validation
  // avoids scanning every path or decoding embedded images on each edit.
  late final EcadException? _validationError = _drawingValidationError(this);

  DrawingElement copyWith({
    String? id,
    DrawingKind? kind,
    Vec2? position,
    double? width,
    double? height,
    double? rotation,
    List<PathSegment>? path,
    Object? stroke = _unchanged,
    Object? fill = _unchanged,
    double? strokeWidth,
    int? lineCap,
    int? lineJoin,
    bool? evenOdd,
    double? opacity,
    List<double>? dash,
    String? text,
    double? fontSize,
    bool? bold,
    String? imageData,
  }) => DrawingElement(
    id: id ?? this.id,
    kind: kind ?? this.kind,
    position: position ?? this.position,
    width: width ?? this.width,
    height: height ?? this.height,
    rotation: rotation ?? this.rotation,
    path: path ?? this.path,
    stroke: identical(stroke, _unchanged) ? this.stroke : stroke as String?,
    fill: identical(fill, _unchanged) ? this.fill : fill as String?,
    strokeWidth: strokeWidth ?? this.strokeWidth,
    lineCap: lineCap ?? this.lineCap,
    lineJoin: lineJoin ?? this.lineJoin,
    evenOdd: evenOdd ?? this.evenOdd,
    opacity: opacity ?? this.opacity,
    dash: dash ?? this.dash,
    text: text ?? this.text,
    fontSize: fontSize ?? this.fontSize,
    bold: bold ?? this.bold,
    imageData: imageData ?? this.imageData,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind.name,
    'position': position.toJson(),
    'width': width,
    'height': height,
    if (rotation != 0) 'rotation': rotation,
    if (kind == DrawingKind.path || path.isNotEmpty)
      'path': path.map((segment) => segment.toJson()).toList(),
    if (stroke != null) 'stroke': stroke,
    if (fill != null) 'fill': fill,
    if (strokeWidth != 1) 'strokeWidth': strokeWidth,
    if (lineCap != 0) 'lineCap': lineCap,
    if (lineJoin != 0) 'lineJoin': lineJoin,
    if (evenOdd) 'evenOdd': evenOdd,
    if (opacity != 1) 'opacity': opacity,
    if (dash.isNotEmpty) 'dash': dash,
    if (kind == DrawingKind.text || text.isNotEmpty) 'text': text,
    if (fontSize != 12) 'fontSize': fontSize,
    if (bold) 'bold': bold,
    if (kind == DrawingKind.image || imageData.isNotEmpty)
      'imageData': imageData,
  };

  factory DrawingElement.fromJson(Object? value) {
    final map = jsonObject(
      value,
      'drawing element',
      allowed: const {
        'id',
        'kind',
        'position',
        'width',
        'height',
        'rotation',
        'path',
        'stroke',
        'fill',
        'strokeWidth',
        'lineCap',
        'lineJoin',
        'evenOdd',
        'opacity',
        'dash',
        'text',
        'fontSize',
        'bold',
        'imageData',
      },
    );
    final kindName = jsonString(map, 'kind');
    final matches = DrawingKind.values.where((kind) => kind.name == kindName);
    if (matches.isEmpty) {
      throw EcadException(
        'Unknown drawing kind "$kindName".',
        code: 'invalid_schema',
      );
    }
    String? color(String key) =>
        map[key] == null ? null : jsonString(map, key, max: 7);
    final element = DrawingElement(
      id: jsonString(map, 'id', max: 128),
      kind: matches.first,
      position: Vec2.fromJson(map['position']),
      width: jsonNumber(map, 'width'),
      height: jsonNumber(map, 'height'),
      rotation: jsonNumber(map, 'rotation', fallback: 0),
      path:
          jsonList(
            map,
            'path',
            max: ProjectLimits.maxPathSegments,
            optional: true,
          ).map(PathSegment.fromJson).toList(),
      stroke: color('stroke'),
      fill: color('fill'),
      strokeWidth: jsonNumber(map, 'strokeWidth', fallback: 1),
      lineCap: jsonInteger(map, 'lineCap', fallback: 0, max: 2),
      lineJoin: jsonInteger(map, 'lineJoin', fallback: 0, max: 2),
      evenOdd: jsonBool(map, 'evenOdd', fallback: false),
      opacity: jsonNumber(map, 'opacity', fallback: 1),
      dash:
          jsonList(
            map,
            'dash',
            max: ProjectLimits.maxDashValues,
            optional: true,
          ).map((n) => jsonNumber({'dash': n}, 'dash')).toList(),
      text: jsonString(
        map,
        'text',
        fallback: '',
        max: ProjectLimits.maxDrawingText,
      ),
      fontSize: jsonNumber(map, 'fontSize', fallback: 12),
      bold: jsonBool(map, 'bold', fallback: false),
      imageData: jsonString(
        map,
        'imageData',
        fallback: '',
        max: ProjectLimits.maxImageBase64Chars,
      ),
    );
    requireValidDrawingElement(element);
    return element;
  }
}

/// Validates direct Dart construction as strictly as decoded drawing elements.
void requireValidDrawingElement(DrawingElement element) {
  final error = element._validationError;
  if (error != null) throw error;
}

final _colorPattern = RegExp(r'^#[0-9a-fA-F]{6}$');

EcadException? _drawingValidationError(DrawingElement element) {
  EcadException error(String message, [String code = 'invalid_geometry']) =>
      EcadException(message, code: code);
  bool bounded(double n) =>
      n.isFinite && n.abs() <= ProjectLimits.maxCoordinate;
  bool point(Vec2 p) => bounded(p.x) && bounded(p.y);
  if (!point(element.position) ||
      !bounded(element.rotation) ||
      !bounded(element.width) ||
      !bounded(element.height) ||
      element.width < 0 ||
      element.height < 0 ||
      (element.kind != DrawingKind.path &&
          (element.width == 0 || element.height == 0))) {
    return error('Drawing position, rotation, or bounds are invalid.');
  }
  if (!bounded(element.strokeWidth) ||
      element.strokeWidth < 0 ||
      !element.opacity.isFinite ||
      element.opacity < 0 ||
      element.opacity > 1 ||
      !bounded(element.fontSize) ||
      element.fontSize <= 0) {
    return error('Drawing stroke width, opacity, or font size is invalid.');
  }
  if (element.lineCap < 0 ||
      element.lineCap > 2 ||
      element.lineJoin < 0 ||
      element.lineJoin > 2) {
    return error(
      'Drawing line cap and join must be 0, 1, or 2.',
      'invalid_schema',
    );
  }
  if ((element.stroke != null && !_colorPattern.hasMatch(element.stroke!)) ||
      (element.fill != null && !_colorPattern.hasMatch(element.fill!))) {
    return error('Drawing colors must be #RRGGBB or null.', 'invalid_schema');
  }
  if (element.dash.length > ProjectLimits.maxDashValues ||
      element.dash.any((n) => !bounded(n) || n < 0) ||
      (element.dash.isNotEmpty && !element.dash.any((n) => n > 0))) {
    return error(
      'Drawing dash pattern must contain bounded nonnegative lengths with a positive total.',
    );
  }
  if (element.text.length > ProjectLimits.maxDrawingText ||
      element.text.contains('\u0000')) {
    return error('Drawing text exceeds the format limits.', 'invalid_schema');
  }
  if (element.path.length > ProjectLimits.maxPathSegments) {
    return error('Drawing path exceeds the segment limit.', 'limit_exceeded');
  }
  if (element.kind != DrawingKind.path && element.path.isNotEmpty ||
      element.kind != DrawingKind.text && element.text.isNotEmpty ||
      element.kind != DrawingKind.image && element.imageData.isNotEmpty) {
    return error('Drawing payload does not match its kind.', 'invalid_schema');
  }
  if (element.kind == DrawingKind.path) {
    if (element.path.isEmpty) return error('Drawing path must not be empty.');
    var hasSubpath = false;
    for (final segment in element.path) {
      if (segment.points.length != segment.verb.pointCount ||
          segment.points.any((p) => !point(p))) {
        return error('Drawing path contains invalid points or verb arity.');
      }
      if (segment.verb == PathVerb.moveTo) {
        hasSubpath = true;
      } else if (!hasSubpath) {
        return error('Drawing path must begin each subpath with M.');
      }
    }
  }
  if (element.kind == DrawingKind.image) {
    return _pngValidationError(element.imageData);
  }
  return null;
}

EcadException? _pngValidationError(String data) {
  const invalid = EcadException(
    'Image data must be raw base64 containing a PNG with bounded dimensions.',
    code: 'invalid_image',
  );
  if (data.length > ProjectLimits.maxImageBase64Chars) {
    return const EcadException(
      'Embedded image exceeds the byte limit.',
      code: 'limit_exceeded',
    );
  }
  // Reject data URLs, URL-safe encoding and whitespace. Portable files contain
  // canonical base64 only, so no renderer can interpret a remote reference.
  if (data.isEmpty ||
      data.length % 4 != 0 ||
      !RegExp(r'^[A-Za-z0-9+/]*={0,2}$').hasMatch(data)) {
    return invalid;
  }
  Uint8List bytes;
  try {
    bytes = base64Decode(data);
  } on FormatException {
    return invalid;
  }
  if (bytes.length > ProjectLimits.maxImageBytes) {
    return const EcadException(
      'Embedded image exceeds the byte limit.',
      code: 'limit_exceeded',
    );
  }
  const signature = [137, 80, 78, 71, 13, 10, 26, 10];
  if (bytes.length < 33) return invalid;
  for (var i = 0; i < signature.length; i++) {
    if (bytes[i] != signature[i]) return invalid;
  }
  final header = ByteData.sublistView(bytes);
  if (header.getUint32(8) != 13 ||
      bytes[12] != 73 ||
      bytes[13] != 72 ||
      bytes[14] != 68 ||
      bytes[15] != 82) {
    return invalid;
  }
  final width = header.getUint32(16);
  final height = header.getUint32(20);
  if (width == 0 ||
      height == 0 ||
      width > ProjectLimits.maxImageDimension ||
      height > ProjectLimits.maxImageDimension ||
      width * height > ProjectLimits.maxImagePixels) {
    return invalid;
  }
  return null;
}
