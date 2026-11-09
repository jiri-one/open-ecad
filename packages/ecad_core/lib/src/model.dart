// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:math' as math;

import 'graphics.dart';
import 'drawing_frames.dart';
import 'domain.dart';
import 'structure.dart';
export 'domain.dart';
export 'drawing_frames.dart';
export 'structure.dart';

/// Shared format limits. Project files are data, never executable instructions.
abstract final class ProjectLimits {
  static const maxPages = 10000;
  static const maxArticles = 20000;
  static const maxComponents = 20000;
  static const maxTerminals = 100000;
  static const maxTerminalReferences = 1000000;
  static const maxPorts = 100000;

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

sealed class WireEndpoint {
  const WireEndpoint();
  String get ownerId;
  Map<String, Object?> toJson();
  factory WireEndpoint.fromJson(Object? value) {
    final map = jsonObject(value, 'endpoint');
    return switch (jsonString(map, 'kind')) {
      'symbol' => TerminalRef.fromJson(value),
      'continuation' => ContinuationRef.fromJson(value),
      'corner' => CornerRef.fromJson(value),
      _ =>
        throw const EcadException(
          'Unknown endpoint kind.',
          code: 'invalid_schema',
        ),
    };
  }
}

enum CornerOrientation {
  topLeft('┌', Vec2(1, 0), Vec2(0, 1)),
  topRight('┐', Vec2(0, 1), Vec2(-1, 0)),
  bottomRight('┘', Vec2(-1, 0), Vec2(0, -1)),
  bottomLeft('└', Vec2(0, -1), Vec2(1, 0));

  const CornerOrientation(this.glyph, this.a, this.b);
  final String glyph;
  final Vec2 a;
  final Vec2 b;
  CornerOrientation get rotated => values[(index + 1) % values.length];
}

class ConnectionCorner {
  const ConnectionCorner({
    required this.id,
    required this.position,
    this.orientation = CornerOrientation.topLeft,
  });
  static const armLength = 10.0;
  static const portIds = ['a', 'b'];
  final String id;
  final Vec2 position;
  final CornerOrientation orientation;

  Vec2? direction(String portId) => switch (portId) {
    'a' => orientation.a,
    'b' => orientation.b,
    _ => null,
  };
  Vec2? portPosition(String portId) =>
      direction(portId) == null
          ? null
          : position + direction(portId)! * armLength;
  List<Vec2> get path => [portPosition('a')!, position, portPosition('b')!];

  ConnectionCorner copyWith({Vec2? position, CornerOrientation? orientation}) =>
      ConnectionCorner(
        id: id,
        position: position ?? this.position,
        orientation: orientation ?? this.orientation,
      );
  Map<String, Object?> toJson() => {
    'id': id,
    'position': position.toJson(),
    'orientation': orientation.name,
  };
  factory ConnectionCorner.fromJson(Object? value) {
    final map = jsonObject(
      value,
      'connection corner',
      allowed: const {'id', 'position', 'orientation'},
    );
    final name = jsonString(map, 'orientation');
    final orientation =
        CornerOrientation.values.where((v) => v.name == name).firstOrNull;
    if (orientation == null) {
      throw const EcadException(
        'Unknown corner orientation.',
        code: 'invalid_schema',
      );
    }
    return ConnectionCorner(
      id: jsonString(map, 'id', max: 128),
      position: Vec2.fromJson(map['position']),
      orientation: orientation,
    );
  }
}

class CornerRef extends WireEndpoint {
  const CornerRef({required this.cornerId, required this.portId});
  final String cornerId;
  final String portId;
  @override
  String get ownerId => cornerId;
  @override
  Map<String, Object?> toJson() => {
    'kind': 'corner',
    'cornerId': cornerId,
    'portId': portId,
  };
  factory CornerRef.fromJson(Object? value) {
    final map = jsonObject(
      value,
      'corner endpoint',
      allowed: const {'kind', 'cornerId', 'portId'},
    );
    if (map['kind'] != 'corner') {
      throw const EcadException(
        'Invalid endpoint kind.',
        code: 'invalid_schema',
      );
    }
    return CornerRef(
      cornerId: jsonString(map, 'cornerId', max: 128),
      portId: jsonString(map, 'portId', max: 128),
    );
  }
  @override
  bool operator ==(Object other) =>
      other is CornerRef &&
      cornerId == other.cornerId &&
      portId == other.portId;
  @override
  int get hashCode => Object.hash('corner', cornerId, portId);
}

class ContinuationRef extends WireEndpoint {
  const ContinuationRef({required this.markerId});
  final String markerId;
  @override
  String get ownerId => markerId;
  @override
  Map<String, Object?> toJson() => {
    'kind': 'continuation',
    'markerId': markerId,
  };
  factory ContinuationRef.fromJson(Object? value) {
    final map = jsonObject(
      value,
      'continuation endpoint',
      allowed: const {'kind', 'markerId'},
    );
    if (map['kind'] != 'continuation')
      throw const EcadException(
        'Invalid endpoint kind.',
        code: 'invalid_schema',
      );
    return ContinuationRef(markerId: jsonString(map, 'markerId', max: 128));
  }
  @override
  bool operator ==(Object other) =>
      other is ContinuationRef && markerId == other.markerId;
  @override
  int get hashCode => Object.hash('continuation', markerId);
}

class TerminalRef extends WireEndpoint {
  const TerminalRef({required this.deviceId, required this.portId});
  final String deviceId;
  final String portId;
  @override
  String get ownerId => deviceId;
  @override
  Map<String, Object?> toJson() => {
    'kind': 'symbol',
    'deviceId': deviceId,
    'portId': portId,
  };
  factory TerminalRef.fromJson(Object? value) {
    final map = jsonObject(
      value,
      'terminal',
      allowed: const {'kind', 'deviceId', 'portId'},
    );
    if (map['kind'] != 'symbol')
      throw const EcadException(
        'Invalid endpoint kind.',
        code: 'invalid_schema',
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
  final WireEndpoint from;
  final WireEndpoint to;
  final List<Vec2> waypoints;
  bool get isAutomatic => false;

  Wire copyWith({
    String? id,
    WireEndpoint? from,
    WireEndpoint? to,
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
      from: WireEndpoint.fromJson(map['from']),
      to: WireEndpoint.fromJson(map['to']),
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

enum SheetType {
  multiLine('Vícepólové schéma'),
  singleLine('Jednopólové schéma'),
  cabinetLayout('Výstavba rozvaděče'),
  form('Formulář'),
  billOfMaterials('Kusovník');

  const SheetType(this.label);
  final String label;
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
    this.structure = const StructureContext.empty(),
    this.documentCode = '',
    this.type = SheetType.multiLine,
    this.width = 1100,
    this.height = 780,
    FrameChoice? frame,
    bool? showFrame,
    Map<String, String> documentFields = const {},
    this.sourcePage,
    this.paperSizeMm = SizeMm.a3Landscape,
    this.mountingView,
    this.report,
    List<ConnectionCorner> corners = const [],
    List<ContinuationMarker> continuations = const [],
    List<Device> devices = const [],
    List<Wire> wires = const [],
    List<DrawingElement> graphics = const [],
  }) : frame = _sheetFrame(frame, showFrame),
       documentFields = Map.unmodifiable(documentFields),
       corners = List.unmodifiable(corners),
       continuations = List.unmodifiable(continuations),
       devices = List.unmodifiable(devices),
       wires = List.unmodifiable(wires),
       graphics = List.unmodifiable(graphics);
  final String id;
  final String name;
  final String number;
  final StructureContext structure;
  final String documentCode;
  final SheetType type;
  final double width;
  final double height;
  final FrameChoice frame;
  final Map<String, String> documentFields;
  bool get showFrame => frame.mode != FrameMode.none;
  final int? sourcePage;
  final SizeMm paperSizeMm;
  final MountingView? mountingView;
  final BomTableSpec? report;
  final List<ConnectionCorner> corners;
  ConnectionCorner? cornerById(String id) => findById(corners, id, (v) => v.id);
  final List<ContinuationMarker> continuations;
  ContinuationMarker? continuationById(String id) =>
      findById(continuations, id, (v) => v.id);
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
    StructureContext? structure,
    String? documentCode,
    SheetType? type,
    double? width,
    double? height,
    bool? showFrame,
    FrameChoice? frame,
    Map<String, String>? documentFields,
    Object? sourcePage = _unchangedSourcePage,
    SizeMm? paperSizeMm,
    Object? mountingView = unchanged,
    Object? report = unchanged,
    List<ConnectionCorner>? corners,
    List<ContinuationMarker>? continuations,
    List<Device>? devices,
    List<Wire>? wires,
    List<DrawingElement>? graphics,
  }) => Sheet(
    id: id ?? this.id,
    name: name ?? this.name,
    number: number ?? this.number,
    structure: structure ?? this.structure,
    documentCode: documentCode ?? this.documentCode,
    type: type ?? this.type,
    width: width ?? this.width,
    height: height ?? this.height,
    frame:
        frame != null || showFrame == false
            ? _sheetFrame(frame, showFrame)
            : showFrame == true && !this.showFrame
            ? const FrameChoice.inherit()
            : this.frame,
    documentFields: documentFields ?? this.documentFields,
    sourcePage:
        identical(sourcePage, _unchangedSourcePage)
            ? this.sourcePage
            : sourcePage as int?,
    paperSizeMm: paperSizeMm ?? this.paperSizeMm,
    mountingView:
        identical(mountingView, unchanged)
            ? this.mountingView
            : mountingView as MountingView?,
    report:
        identical(report, unchanged) ? this.report : report as BomTableSpec?,
    corners: corners ?? this.corners,
    continuations: continuations ?? this.continuations,
    devices: devices ?? this.devices,
    wires: wires ?? this.wires,
    graphics: graphics ?? this.graphics,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'number': number,
    if (!structure.isEmpty) 'structure': structure.toJson(),
    if (documentCode.isNotEmpty) 'documentCode': documentCode,
    'type': type.name,
    'width': width,
    'height': height,
    'frame': frame.toJson(),
    'documentFields': documentFields,
    if (sourcePage != null) 'sourcePage': sourcePage,
    'paperSizeMm': paperSizeMm.toJson(),
    if (mountingView != null) 'mountingView': mountingView!.toJson(),
    if (report != null) 'report': report!.toJson(),
    if (corners.isNotEmpty) 'corners': corners.map((v) => v.toJson()).toList(),
    'continuations': continuations.map((v) => v.toJson()).toList(),
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
        'structure',
        'documentCode',
        'type',
        'width',
        'height',
        'showFrame',
        'frame',
        'documentFields',
        'sourcePage',
        'paperSizeMm',
        'mountingView',
        'report',
        'corners',
        'continuations',
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
      structure: StructureContext.fromJson(map['structure']),
      documentCode: jsonString(map, 'documentCode', max: 64, fallback: ''),
      type: jsonSheetType(map, 'type'),
      paperSizeMm: SizeMm.fromJson(map['paperSizeMm']),
      mountingView:
          map['mountingView'] == null
              ? null
              : MountingView.fromJson(map['mountingView']),
      report:
          map['report'] == null ? null : BomTableSpec.fromJson(map['report']),
      corners:
          jsonList(
            map,
            'corners',
            max: ProjectLimits.maxDevices,
            optional: true,
          ).map(ConnectionCorner.fromJson).toList(),
      continuations:
          jsonList(
            map,
            'continuations',
            max: ProjectLimits.maxDevices,
          ).map(ContinuationMarker.fromJson).toList(),
      width: width,
      height: height,
      frame:
          map.containsKey('frame') ? FrameChoice.fromJson(map['frame']) : null,
      showFrame:
          map.containsKey('showFrame')
              ? jsonBool(map, 'showFrame', fallback: true)
              : null,
      documentFields:
          map.containsKey('documentFields')
              ? decodeDocumentFields(map['documentFields'])
              : const {},
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

FrameChoice _sheetFrame(FrameChoice? frame, bool? showFrame) {
  if (frame != null && showFrame != null) {
    throw const EcadException(
      'Specify frame or showFrame, not both.',
      code: 'invalid_frame_choice',
    );
  }
  return frame ??
      (showFrame == false
          ? const FrameChoice.none()
          : const FrameChoice.inherit());
}

const _unchangedSourcePage = Object();

class EcadProject {
  EcadProject({
    required this.id,
    required this.name,
    this.description = '',
    this.revision = 0,
    List<FrameTemplate>? frameTemplates,
    this.defaultFrame = const FrameChoice.template(FrameTemplates.builtinId),
    Map<String, String> documentFields = const {},
    required List<Sheet> pages,
    List<Article> articles = const [],
    List<Component> components = const [],
    List<ContinuationLink> continuationLinks = const [],
    List<TerminalStrip> terminalStrips = const [],
    List<MountingLayout> mountingLayouts = const [],
  }) : frameTemplates = List.unmodifiable(
         frameTemplates ?? [FrameTemplates.builtin],
       ),
       documentFields = Map.unmodifiable(documentFields),
       terminalStrips = List.unmodifiable(terminalStrips),
       articles = List.unmodifiable(articles),
       components = List.unmodifiable(components),
       continuationLinks = List.unmodifiable(continuationLinks),
       mountingLayouts = List.unmodifiable(mountingLayouts),
       pages = List.unmodifiable(pages);
  static const format = 'open-ecad';

  static const formatVersion = 6;
  final String id;
  final String name;
  final String description;
  final int revision;
  final List<FrameTemplate> frameTemplates;
  final FrameChoice defaultFrame;
  final Map<String, String> documentFields;
  FrameTemplate? frameTemplateById(String id) =>
      findById(frameTemplates, id, (t) => t.id);
  final List<Sheet> pages;
  final List<Article> articles;
  final List<Component> components;
  final List<ContinuationLink> continuationLinks;
  final List<TerminalStrip> terminalStrips;
  TerminalStrip? terminalStripById(String id) =>
      findById(terminalStrips, id, (s) => s.id);
  final List<MountingLayout> mountingLayouts;
  Article? articleById(String id) => findById(articles, id, (v) => v.id);
  Component? componentById(String id) => findById(components, id, (v) => v.id);
  ContinuationLink? continuationLinkById(String id) =>
      findById(continuationLinks, id, (v) => v.id);
  MountingLayout? mountingLayoutById(String id) =>
      findById(mountingLayouts, id, (v) => v.id);

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
    List<FrameTemplate>? frameTemplates,
    FrameChoice? defaultFrame,
    Map<String, String>? documentFields,
    List<Sheet>? pages,
    List<Article>? articles,
    List<Component>? components,
    List<ContinuationLink>? continuationLinks,
    List<TerminalStrip>? terminalStrips,
    List<MountingLayout>? mountingLayouts,
  }) => EcadProject(
    id: id ?? this.id,
    name: name ?? this.name,
    description: description ?? this.description,
    revision: revision ?? this.revision,
    frameTemplates: frameTemplates ?? this.frameTemplates,
    defaultFrame: defaultFrame ?? this.defaultFrame,
    documentFields: documentFields ?? this.documentFields,
    pages: pages ?? this.pages,
    articles: articles ?? this.articles,
    components: components ?? this.components,
    continuationLinks: continuationLinks ?? this.continuationLinks,
    terminalStrips: terminalStrips ?? this.terminalStrips,
    mountingLayouts: mountingLayouts ?? this.mountingLayouts,
  );

  Map<String, Object?> toJson() => {
    'format': format,
    'formatVersion': formatVersion,
    'id': id,
    'name': name,
    'description': description,
    'revision': revision,
    'frameTemplates': frameTemplates.map((v) => v.toJson()).toList(),
    'defaultFrame': defaultFrame.toJson(),
    'documentFields': documentFields,
    'articles': articles.map((v) => v.toJson()).toList(),
    'components': components.map((v) => v.toJson()).toList(),
    'continuationLinks': continuationLinks.map((v) => v.toJson()).toList(),
    if (terminalStrips.isNotEmpty)
      'terminalStrips': terminalStrips.map((v) => v.toJson()).toList(),
    'mountingLayouts': mountingLayouts.map((v) => v.toJson()).toList(),
    'pages': pages.map((p) => p.toJson()).toList(),
  };

  /// Use ProjectEngine or requireValidProject to check reference integrity.
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
        'frameTemplates',
        'defaultFrame',
        'documentFields',
        'pages',
        'articles',
        'components',
        'continuationLinks',
        'terminalStrips',
        'mountingLayouts',
      },
    );
    final version = map['formatVersion'];
    if (map['format'] != format ||
        version is! int ||
        (version != formatVersion && version != 5 && version != 4)) {
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
    final rawArticles = jsonList(
      map,
      'articles',
      max: ProjectLimits.maxArticles,
    );
    final rawComponents = jsonList(
      map,
      'components',
      max: ProjectLimits.maxComponents,
    );
    final rawLinks = jsonList(
      map,
      'continuationLinks',
      max: ProjectLimits.maxDevices,
    );
    final rawLayouts = jsonList(
      map,
      'mountingLayouts',
      max: ProjectLimits.maxPages,
    );
    var terminals = 0;
    var terminalRefs = 0;
    var placements = 0;
    for (final raw in rawComponents) {
      final component = jsonObject(raw, 'component');
      if (component['electrical'] case final value?) {
        final electrical = jsonObject(value, 'electrical');
        terminals += jsonList(electrical, 'terminals', max: 256).length;
        for (final rawFunction in jsonList(electrical, 'functions', max: 64)) {
          terminalRefs +=
              jsonList(
                jsonObject(rawFunction, 'function'),
                'terminalIds',
                max: 256,
              ).length;
        }
        if (terminals > ProjectLimits.maxTerminals ||
            terminalRefs > ProjectLimits.maxTerminalReferences) {
          throw const EcadException(
            'Too many electrical terminals or references.',
            code: 'limit_exceeded',
          );
        }
      }
    }
    for (final raw in rawLayouts) {
      placements +=
          jsonList(
            jsonObject(raw, 'mounting layout'),
            'placements',
            max: ProjectLimits.maxDevices,
          ).length;
      if (placements > ProjectLimits.maxDevices)
        throw const EcadException(
          'Too many mounting placements.',
          code: 'limit_exceeded',
        );
    }
    var portCount = 0;
    var markerCount = 0;
    var cornerCount = 0;
    final rawPages = jsonList(map, 'pages', max: ProjectLimits.maxPages);
    var deviceCount = 0;
    var wireCount = 0;
    var graphicCount = 0;
    var segmentCount = 0;
    var imageChars = 0;
    // Enforce whole-project limits before allocating domain object collections.
    for (final raw in rawPages) {
      final page = jsonObject(raw, 'sheet');
      cornerCount +=
          jsonList(
            page,
            'corners',
            max: ProjectLimits.maxDevices,
            optional: true,
          ).length;
      markerCount +=
          jsonList(page, 'continuations', max: ProjectLimits.maxDevices).length;
      for (final rawDevice in jsonList(
        page,
        'devices',
        max: ProjectLimits.maxDevices,
      )) {
        final symbol = jsonObject(
          jsonObject(rawDevice, 'device')['symbol'],
          'symbol',
        );
        if (symbol['type'] == 'block') {
          portCount += jsonList(symbol, 'ports', max: 256).length;
        } else if (symbol['type'] == 'terminal') {
          portCount += jsonList(symbol, 'sides', max: 4).length;
        } else {
          final bindings = jsonObject(symbol['bindings'], 'bindings');
          if (bindings.length > 256)
            throw const EcadException(
              'Too many symbol bindings.',
              code: 'limit_exceeded',
            );
          portCount += bindings.length;
        }
      }
      if (portCount > ProjectLimits.maxPorts ||
          markerCount > ProjectLimits.maxDevices ||
          cornerCount > ProjectLimits.maxDevices)
        throw const EcadException(
          'Too many symbol ports or continuation markers.',
          code: 'limit_exceeded',
        );
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
      frameTemplates:
          version < 6 && !map.containsKey('frameTemplates')
              ? null
              : jsonList(
                map,
                'frameTemplates',
                max: FrameLimits.templates,
              ).map(FrameTemplate.fromJson).toList(),
      defaultFrame:
          version < 6 && !map.containsKey('defaultFrame')
              ? const FrameChoice.template(FrameTemplates.builtinId)
              : FrameChoice.fromJson(map['defaultFrame']),
      documentFields:
          map.containsKey('documentFields')
              ? decodeDocumentFields(map['documentFields'])
              : const {},
      pages: rawPages.map(Sheet.fromJson).toList(),
      articles: rawArticles.map(Article.fromJson).toList(),
      components: rawComponents.map(Component.fromJson).toList(),
      continuationLinks: rawLinks.map(ContinuationLink.fromJson).toList(),
      terminalStrips:
          jsonList(
            map,
            'terminalStrips',
            max: ProjectLimits.maxComponents,
            optional: true,
          ).map(TerminalStrip.fromJson).toList(),
      mountingLayouts: rawLayouts.map(MountingLayout.fromJson).toList(),
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
