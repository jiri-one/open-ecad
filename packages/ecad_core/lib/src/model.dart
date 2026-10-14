// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:math' as math;

import 'graphics.dart';

/// Shared format limits. Project files are data, never executable instructions.
abstract final class ProjectLimits {
  static const maxPages = 1024;

  /// A sheet may come from any page of a much longer source document.
  static const maxSourcePage = 1000000;
  static const maxDevices = 20000;
  static const maxWires = 40000;
  static const maxWaypoints = 256;
  static const maxGraphics = 500000;
  static const maxPathSegments = 10000;
  static const maxTotalPathSegments = 4000000;
  static const maxDashValues = 64;
  static const maxDrawingText = 65536;
  static const maxImageBytes = 16 * 1024 * 1024;
  static const maxImageBase64Chars = ((maxImageBytes + 2) ~/ 3) * 4;
  static const maxTotalImageBytes = 64 * 1024 * 1024;
  static const maxTotalImageBase64Chars = ((maxTotalImageBytes + 2) ~/ 3) * 4;
  static const maxImageDimension = 16384;
  static const maxImagePixels = 64 * 1024 * 1024;
  static const maxCommands = 1000;
  static const maxCoordinate = 1000000.0;
  static const maxRevision = 9007199254740990;
  static const maxFileBytes = 128 * 1024 * 1024;
}

class EcadException implements Exception {
  const EcadException(this.message, {this.code = 'invalid_project'});
  final String message;
  final String code;

  @override
  String toString() => 'EcadException ($code): $message';
}

class Vec2 {
  const Vec2(this.x, this.y);
  final double x;
  final double y;
  static const zero = Vec2(0, 0);

  Vec2 operator +(Vec2 other) => Vec2(x + other.x, y + other.y);
  Vec2 operator -(Vec2 other) => Vec2(x - other.x, y - other.y);
  Vec2 operator *(double scale) => Vec2(x * scale, y * scale);
  Vec2 operator /(double scale) => Vec2(x / scale, y / scale);
  Vec2 operator -() => Vec2(-x, -y);
  double get lengthSquared => x * x + y * y;
  double get length => math.sqrt(lengthSquared);
  double distanceTo(Vec2 other) => (this - other).length;
  double distanceSquaredTo(Vec2 other) => (this - other).lengthSquared;
  Vec2 snapped(double grid) {
    if (!grid.isFinite || grid <= 0) {
      throw const EcadException('Grid spacing must be positive and finite.');
    }
    return Vec2((x / grid).round() * grid, (y / grid).round() * grid);
  }

  Vec2 rotated(double degrees) {
    final radians = degrees * math.pi / 180;
    final c = math.cos(radians);
    final s = math.sin(radians);
    return Vec2(x * c - y * s, x * s + y * c);
  }

  Map<String, Object?> toJson() => {'x': x, 'y': y};
  factory Vec2.fromJson(Object? value) {
    final map = jsonObject(value, 'point', allowed: const {'x', 'y'});
    return Vec2(jsonNumber(map, 'x'), jsonNumber(map, 'y'));
  }

  @override
  bool operator ==(Object other) =>
      other is Vec2 && x == other.x && y == other.y;
  @override
  int get hashCode => Object.hash(x, y);
  @override
  String toString() => 'Vec2($x, $y)';
}

/// Serialized by name; the declaration order is only the library order.
enum DeviceKind {
  supply,
  breaker,
  threePoleBreaker,
  fuse,
  disconnector,
  threePoleDisconnector,
  contactor,
  motor,
  transformer,
  currentTransformer,
  terminal,
  earth,
  contactNo,
  contactNc,
  pushbuttonNo,
  coil,
  lamp,
  ammeter,
  voltmeter,
}

class Device {
  const Device({
    required this.id,
    required this.kind,
    required this.designation,
    required this.position,
    this.description = '',
    this.rating = '',
    this.rotation = 0,
  });

  final String id;
  final DeviceKind kind;
  final String designation;
  final Vec2 position;
  final String description;
  final String rating;
  final double rotation;

  Device copyWith({
    String? id,
    DeviceKind? kind,
    String? designation,
    Vec2? position,
    String? description,
    String? rating,
    double? rotation,
  }) => Device(
    id: id ?? this.id,
    kind: kind ?? this.kind,
    designation: designation ?? this.designation,
    position: position ?? this.position,
    description: description ?? this.description,
    rating: rating ?? this.rating,
    rotation: rotation ?? this.rotation,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind.name,
    'designation': designation,
    'position': position.toJson(),
    'description': description,
    'rating': rating,
    'rotation': rotation,
  };

  factory Device.fromJson(Object? value) {
    final map = jsonObject(
      value,
      'device',
      allowed: const {
        'id',
        'kind',
        'designation',
        'position',
        'description',
        'rating',
        'rotation',
      },
    );
    final kindName = jsonString(map, 'kind');
    final kinds = DeviceKind.values.where((kind) => kind.name == kindName);
    if (kinds.isEmpty) {
      throw EcadException(
        'Unknown device kind "$kindName".',
        code: 'invalid_schema',
      );
    }
    return Device(
      id: jsonString(map, 'id', max: 128),
      kind: kinds.first,
      designation: jsonString(map, 'designation', max: 64),
      position: Vec2.fromJson(map['position']),
      description: jsonString(map, 'description', fallback: '', max: 8192),
      rating: jsonString(map, 'rating', fallback: '', max: 128),
      rotation: jsonNumber(map, 'rotation', fallback: 0),
    );
  }
}

class TerminalRef {
  const TerminalRef({required this.deviceId, required this.portId});
  final String deviceId;
  final String portId;
  Map<String, Object?> toJson() => {'deviceId': deviceId, 'portId': portId};
  factory TerminalRef.fromJson(Object? value) {
    final map = jsonObject(
      value,
      'terminal',
      allowed: const {'deviceId', 'portId'},
    );
    return TerminalRef(
      deviceId: jsonString(map, 'deviceId', max: 128),
      portId: jsonString(map, 'portId', max: 128),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is TerminalRef &&
      deviceId == other.deviceId &&
      portId == other.portId;
  @override
  int get hashCode => Object.hash(deviceId, portId);
  @override
  String toString() => '$deviceId:$portId';
}

class Wire {
  Wire({
    required this.id,
    required this.from,
    required this.to,
    List<Vec2> waypoints = const [],
  }) : waypoints = List.unmodifiable(waypoints);
  final String id;
  final TerminalRef from;
  final TerminalRef to;
  final List<Vec2> waypoints;

  Wire copyWith({
    String? id,
    TerminalRef? from,
    TerminalRef? to,
    List<Vec2>? waypoints,
  }) => Wire(
    id: id ?? this.id,
    from: from ?? this.from,
    to: to ?? this.to,
    waypoints: waypoints ?? this.waypoints,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'from': from.toJson(),
    'to': to.toJson(),
    'waypoints': waypoints.map((p) => p.toJson()).toList(),
  };
  factory Wire.fromJson(Object? value) {
    final map = jsonObject(
      value,
      'wire',
      allowed: const {'id', 'from', 'to', 'waypoints'},
    );
    return Wire(
      id: jsonString(map, 'id', max: 128),
      from: TerminalRef.fromJson(map['from']),
      to: TerminalRef.fromJson(map['to']),
      waypoints:
          jsonList(
            map,
            'waypoints',
            max: ProjectLimits.maxWaypoints,
            optional: true,
          ).map(Vec2.fromJson).toList(),
    );
  }
}

/// Editing, connectivity and validation rules are identical for every type;
/// the type only names and organizes the page.
enum SheetType {
  multiLine('Vícepólové schéma'),
  singleLine('Jednopólové schéma'),
  cabinetLayout('Výstavba rozvaděče'),
  form('Formulář');

  const SheetType(this.label);
  final String label;

  /// Compatibility fallback when a document or command names no type; it
  /// says nothing about what an older or unclassified page actually shows.
  static const legacyDefault = SheetType.multiLine;
}

/// An absent [key] means "unspecified" and takes [fallback]; null or an
/// unknown name is invalid data and is never silently defaulted.
SheetType jsonSheetType(
  Map<String, Object?> map,
  String key, {
  SheetType? fallback,
}) {
  final name = jsonString(map, key, fallback: fallback?.name, max: 40);
  for (final type in SheetType.values) {
    if (type.name == name) return type;
  }
  throw EcadException('Unknown sheet type "$name".', code: 'invalid_schema');
}

class Sheet {
  Sheet({
    required this.id,
    required this.name,
    required this.number,
    this.type = SheetType.legacyDefault,
    this.width = 1100,
    this.height = 780,
    this.showFrame = true,
    this.sourcePage,
    List<Device> devices = const [],
    List<Wire> wires = const [],
    List<DrawingElement> graphics = const [],
  }) : devices = List.unmodifiable(devices),
       wires = List.unmodifiable(wires),
       graphics = List.unmodifiable(graphics);
  final String id;
  final String name;
  final String number;
  final SheetType type;
  final double width;
  final double height;
  final bool showFrame;
  final int? sourcePage;
  final List<Device> devices;
  final List<Wire> wires;
  final List<DrawingElement> graphics;

  Device? deviceById(String id) {
    for (final device in devices) {
      if (device.id == id) return device;
    }
    return null;
  }

  DrawingElement? graphicById(String id) {
    for (final graphic in graphics) {
      if (graphic.id == id) return graphic;
    }
    return null;
  }

  Sheet copyWith({
    String? id,
    String? name,
    String? number,
    SheetType? type,
    double? width,
    double? height,
    bool? showFrame,
    Object? sourcePage = _unchangedSourcePage,
    List<Device>? devices,
    List<Wire>? wires,
    List<DrawingElement>? graphics,
  }) => Sheet(
    id: id ?? this.id,
    name: name ?? this.name,
    number: number ?? this.number,
    type: type ?? this.type,
    width: width ?? this.width,
    height: height ?? this.height,
    showFrame: showFrame ?? this.showFrame,
    sourcePage:
        identical(sourcePage, _unchangedSourcePage)
            ? this.sourcePage
            : sourcePage as int?,
    devices: devices ?? this.devices,
    wires: wires ?? this.wires,
    graphics: graphics ?? this.graphics,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'number': number,
    'type': type.name,
    'width': width,
    'height': height,
    'showFrame': showFrame,
    if (sourcePage != null) 'sourcePage': sourcePage,
    'devices': devices.map((d) => d.toJson()).toList(),
    'wires': wires.map((w) => w.toJson()).toList(),
    'graphics': graphics.map((g) => g.toJson()).toList(),
  };

  factory Sheet.fromJson(Object? value) {
    final map = jsonObject(
      value,
      'sheet',
      allowed: const {
        'id',
        'name',
        'number',
        'type',
        'width',
        'height',
        'showFrame',
        'sourcePage',
        'devices',
        'wires',
        'graphics',
      },
    );
    final width = jsonNumber(map, 'width', fallback: 1100);
    final height = jsonNumber(map, 'height', fallback: 780);
    final sourcePage =
        map['sourcePage'] == null
            ? null
            : jsonInteger(map, 'sourcePage', max: ProjectLimits.maxSourcePage);
    if (width <= 0 || height <= 0) {
      throw const EcadException(
        'Sheet width and height must be positive.',
        code: 'invalid_geometry',
      );
    }
    if (sourcePage == 0) {
      throw const EcadException(
        'Source page is numbered from 1.',
        code: 'invalid_metadata',
      );
    }
    return Sheet(
      id: jsonString(map, 'id', max: 128),
      name: jsonString(map, 'name', max: 200),
      number: jsonString(map, 'number', max: 32),
      type: jsonSheetType(map, 'type', fallback: SheetType.legacyDefault),
      width: width,
      height: height,
      showFrame: jsonBool(map, 'showFrame', fallback: true),
      sourcePage: sourcePage,
      devices:
          jsonList(
            map,
            'devices',
            max: ProjectLimits.maxDevices,
          ).map(Device.fromJson).toList(),
      wires:
          jsonList(
            map,
            'wires',
            max: ProjectLimits.maxWires,
          ).map(Wire.fromJson).toList(),
      graphics:
          jsonList(
            map,
            'graphics',
            max: ProjectLimits.maxGraphics,
            optional: true,
          ).map(DrawingElement.fromJson).toList(),
    );
  }
}

const _unchangedSourcePage = Object();

class EcadProject {
  EcadProject({
    required this.id,
    required this.name,
    this.description = '',
    this.revision = 0,
    required List<Sheet> pages,
  }) : pages = List.unmodifiable(pages);
  static const format = 'open-ecad';

  /// Bumped whenever written files gain fields that older strict readers
  /// reject, so they report an unsupported format instead of a schema error.
  static const formatVersion = 3;
  final String id;
  final String name;
  final String description;
  final int revision;
  final List<Sheet> pages;

  Sheet? sheetById(String id) {
    for (final page in pages) {
      if (page.id == id) return page;
    }
    return null;
  }

  EcadProject copyWith({
    String? id,
    String? name,
    String? description,
    int? revision,
    List<Sheet>? pages,
  }) => EcadProject(
    id: id ?? this.id,
    name: name ?? this.name,
    description: description ?? this.description,
    revision: revision ?? this.revision,
    pages: pages ?? this.pages,
  );

  Map<String, Object?> toJson() => {
    'format': format,
    'formatVersion': formatVersion,
    'id': id,
    'name': name,
    'description': description,
    'revision': revision,
    'pages': pages.map((p) => p.toJson()).toList(),
  };

  /// Reads v1 to v3. Fields that older versions lack (v1 page bounds, frame
  /// and graphics; v1–v2 sheet type) get compatibility defaults.
  /// Use [ProjectEngine] or validateProject to also check graph consistency.
  factory EcadProject.fromJson(Object? value) {
    final map = jsonObject(
      value,
      'project',
      allowed: const {
        'format',
        'formatVersion',
        'id',
        'name',
        'description',
        'revision',
        'pages',
      },
    );
    final version = map['formatVersion'];
    if (map['format'] != format ||
        version is! int ||
        version < 1 ||
        version > formatVersion) {
      throw const EcadException(
        'Unsupported project format or formatVersion.',
        code: 'unsupported_format',
      );
    }
    final revision = jsonInteger(
      map,
      'revision',
      fallback: 0,
      max: ProjectLimits.maxRevision,
    );
    final rawPages = jsonList(map, 'pages', max: ProjectLimits.maxPages);
    var deviceCount = 0;
    var wireCount = 0;
    var graphicCount = 0;
    var segmentCount = 0;
    var imageChars = 0;
    // Enforce whole-project limits before allocating domain object collections.
    for (final raw in rawPages) {
      final page = jsonObject(raw, 'sheet');
      deviceCount +=
          jsonList(page, 'devices', max: ProjectLimits.maxDevices).length;
      wireCount += jsonList(page, 'wires', max: ProjectLimits.maxWires).length;
      final graphics = jsonList(
        page,
        'graphics',
        max: ProjectLimits.maxGraphics,
        optional: true,
      );
      graphicCount += graphics.length;
      if (deviceCount > ProjectLimits.maxDevices ||
          wireCount > ProjectLimits.maxWires ||
          graphicCount > ProjectLimits.maxGraphics) {
        throw const EcadException(
          'Project exceeds the device, wire, or drawing element limit.',
          code: 'limit_exceeded',
        );
      }
      for (final rawGraphic in graphics) {
        final graphic = jsonObject(rawGraphic, 'drawing element');
        segmentCount +=
            jsonList(
              graphic,
              'path',
              max: ProjectLimits.maxPathSegments,
              optional: true,
            ).length;
        imageChars +=
            jsonString(
              graphic,
              'imageData',
              fallback: '',
              max: ProjectLimits.maxImageBase64Chars,
            ).length;
        if (segmentCount > ProjectLimits.maxTotalPathSegments ||
            imageChars > ProjectLimits.maxTotalImageBase64Chars) {
          throw const EcadException(
            'Project exceeds the path segment or embedded image limit.',
            code: 'limit_exceeded',
          );
        }
      }
    }
    return EcadProject(
      id: jsonString(map, 'id', max: 128),
      name: jsonString(map, 'name', max: 200),
      description: jsonString(map, 'description', fallback: '', max: 8192),
      revision: revision,
      pages: rawPages.map(Sheet.fromJson).toList(),
    );
  }
}

final _random = math.Random.secure();
int _idCounter = 0;

/// An opaque identifier suitable for offline projects; not a security token.
String newId(String prefix) {
  if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9_-]{0,23}$').hasMatch(prefix)) {
    throw const EcadException('ID prefix must contain 1–24 simple characters.');
  }
  final time = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  final counter = (_idCounter++).toRadixString(36);
  final entropy =
      List.generate(
        3,
        (_) => _random.nextInt(1 << 30).toRadixString(36).padLeft(6, '0'),
      ).join();
  return '${prefix}_${time}_${counter}_$entropy';
}

// Shared strict decoders, exported for the command codec.
Map<String, Object?> jsonObject(
  Object? value,
  String context, {
  Set<String>? allowed,
}) {
  if (value is! Map || value.keys.any((Object? key) => key is! String)) {
    throw EcadException('$context must be an object.', code: 'invalid_schema');
  }
  final map = Map<String, Object?>.from(value);
  if (allowed != null) {
    final unknown = map.keys.where((key) => !allowed.contains(key)).toList();
    if (unknown.isNotEmpty) {
      throw EcadException(
        'Unknown $context fields: ${unknown.join(', ')}.',
        code: 'invalid_schema',
      );
    }
  }
  return map;
}

String jsonString(
  Map<String, Object?> map,
  String key, {
  String? fallback,
  int max = 200,
}) {
  final value = map.containsKey(key) ? map[key] : fallback;
  if (value is! String || value.length > max || value.contains('\u0000')) {
    throw EcadException(
      '$key must be a string of at most $max characters without NUL.',
      code: 'invalid_schema',
    );
  }
  return value;
}

double jsonNumber(Map<String, Object?> map, String key, {double? fallback}) {
  final value = map.containsKey(key) ? map[key] : fallback;
  if (value is! num ||
      !value.isFinite ||
      value.abs() > ProjectLimits.maxCoordinate) {
    throw EcadException(
      '$key must be finite and within ±${ProjectLimits.maxCoordinate.toInt()}.',
      code: 'invalid_geometry',
    );
  }
  return value.toDouble();
}

bool jsonBool(Map<String, Object?> map, String key, {required bool fallback}) {
  final value = map.containsKey(key) ? map[key] : fallback;
  if (value is! bool) {
    throw EcadException('$key must be a boolean.', code: 'invalid_schema');
  }
  return value;
}

int jsonInteger(
  Map<String, Object?> map,
  String key, {
  int? fallback,
  int max = ProjectLimits.maxRevision,
}) {
  final value = map.containsKey(key) ? map[key] : fallback;
  if (value is! int || value < 0 || value > max) {
    throw EcadException(
      '$key must be an integer between 0 and $max.',
      code: 'invalid_schema',
    );
  }
  return value;
}

List<Object?> jsonList(
  Map<String, Object?> map,
  String key, {
  required int max,
  bool optional = false,
}) {
  final value =
      !map.containsKey(key) && optional ? const <Object?>[] : map[key];
  if (value is! List || value.length > max) {
    throw EcadException(
      '$key must be a list of at most $max items.',
      code: 'limit_exceeded',
    );
  }
  return List<Object?>.from(value);
}
