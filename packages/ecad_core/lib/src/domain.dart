// SPDX-License-Identifier: GPL-3.0-or-later
import 'model.dart';

const unchanged = Object();

enum QuantityUnit { piece, metre }

enum ComponentKind { physical, material }

enum ComponentUsage { installed, spare }

enum ProcurementSource { purchase, available, included }

enum OccurrenceMode { wiring, reference }

enum PortSide { left, right, top, bottom }

enum ContinuationGlyph { arrow, earth }

enum BomReportKind { articles, components }

T jsonEnum<T extends Enum>(
  Map<String, Object?> map,
  String key,
  List<T> values,
) {
  final name = jsonString(map, key);
  for (final value in values) {
    if (value.name == name) return value;
  }
  throw EcadException('Unknown $key "$name".', code: 'invalid_schema');
}

class Quantity {
  const Quantity({required this.unit, required this.baseUnits});
  const Quantity.pieces(int? amount)
    : unit = QuantityUnit.piece,
      baseUnits = amount;
  const Quantity.millimetres(int? amount)
    : unit = QuantityUnit.metre,
      baseUnits = amount;
  final QuantityUnit unit;
  final int? baseUnits;
  static const maxBaseUnits = 100000000000;

  String? get amount {
    final n = baseUnits;
    if (n == null) return null;
    if (n < 0 || n > maxBaseUnits) {
      throw const EcadException(
        'Quantity is outside the supported range.',
        code: 'invalid_quantity',
      );
    }
    return formatBaseUnits(unit, n);
  }

  static String formatBaseUnits(QuantityUnit unit, int n) {
    if (n < 0 || n > ProjectLimits.maxRevision) {
      throw const EcadException(
        'Quantity total is outside the exact integer range.',
        code: 'invalid_quantity',
      );
    }
    if (unit == QuantityUnit.piece) return '$n';
    final fraction = (n % 1000)
        .toString()
        .padLeft(3, '0')
        .replaceFirst(RegExp(r'0+$'), '');
    return '${n ~/ 1000}${fraction.isEmpty ? '' : '.$fraction'}';
  }

  factory Quantity.parse(QuantityUnit unit, String? amount) {
    if (amount == null) return Quantity(unit: unit, baseUnits: null);
    final pattern =
        unit == QuantityUnit.piece
            ? r'^[0-9]{1,12}$'
            : r'^[0-9]{1,12}(\.[0-9]{1,3})?$';
    if (!RegExp(pattern).hasMatch(amount)) {
      throw const EcadException(
        'Quantity must be a positive decimal string (pieces integral, metres to mm).',
        code: 'invalid_quantity',
      );
    }
    final parts = amount.split('.');
    final n =
        unit == QuantityUnit.piece
            ? int.parse(parts[0])
            : int.parse(parts[0]) * 1000 +
                int.parse(parts.length == 1 ? '0' : parts[1].padRight(3, '0'));
    if (n <= 0 || n > maxBaseUnits) {
      throw const EcadException(
        'Quantity is outside the supported range.',
        code: 'invalid_quantity',
      );
    }
    return Quantity(unit: unit, baseUnits: n);
  }

  Quantity copyWith({QuantityUnit? unit, Object? baseUnits = unchanged}) =>
      Quantity(
        unit: unit ?? this.unit,
        baseUnits:
            identical(baseUnits, unchanged)
                ? this.baseUnits
                : baseUnits as int?,
      );
  Map<String, Object?> toJson() => {'unit': unit.name, 'amount': amount};
  factory Quantity.fromJson(Object? value) {
    final map = jsonObject(
      value,
      'quantity',
      allowed: const {'unit', 'amount'},
    );
    if (!map.containsKey('amount') ||
        (map['amount'] != null && map['amount'] is! String)) {
      throw const EcadException(
        'Quantity amount must be a string or null.',
        code: 'invalid_schema',
      );
    }
    return Quantity.parse(
      jsonEnum(map, 'unit', QuantityUnit.values),
      map['amount'] as String?,
    );
  }
}

sealed class SymbolSpec {
  const SymbolSpec();
  Map<String, Object?> toJson();
  factory SymbolSpec.fromJson(Object? value) {
    final map = jsonObject(value, 'symbol');
    return switch (jsonString(map, 'type')) {
      'builtin' => BuiltinSymbolSpec.fromJson(value),
      'block' => PortBlockSpec.fromJson(value),
      'terminal' => TerminalSymbolSpec.fromJson(value),
      _ =>
        throw const EcadException(
          'Unknown symbol type.',
          code: 'invalid_schema',
        ),
    };
  }
}

class DimensionsMm {
  const DimensionsMm({this.width, this.height, this.depth});
  final double? width;
  final double? height;
  final double? depth;
  DimensionsMm copyWith({
    Object? width = unchanged,
    Object? height = unchanged,
    Object? depth = unchanged,
  }) => DimensionsMm(
    width: identical(width, unchanged) ? this.width : width as double?,
    height: identical(height, unchanged) ? this.height : height as double?,
    depth: identical(depth, unchanged) ? this.depth : depth as double?,
  );
  Map<String, Object?> toJson() => {
    if (width != null) 'width': width,
    if (height != null) 'height': height,
    if (depth != null) 'depth': depth,
  };
  factory DimensionsMm.fromJson(Object? value) {
    final map = jsonObject(
      value,
      'DimensionsMm',
      allowed: const {'width', 'height', 'depth'},
    );
    return DimensionsMm(
      width: map['width'] == null ? null : jsonNumber(map, 'width'),
      height: map['height'] == null ? null : jsonNumber(map, 'height'),
      depth: map['depth'] == null ? null : jsonNumber(map, 'depth'),
    );
  }
}

class SizeMm {
  const SizeMm({required this.width, required this.height});
  final double width;
  final double height;
  SizeMm copyWith({double? width, double? height}) =>
      SizeMm(width: width ?? this.width, height: height ?? this.height);
  Map<String, Object?> toJson() => {'width': width, 'height': height};
  factory SizeMm.fromJson(Object? value) {
    final map = jsonObject(value, 'SizeMm', allowed: const {'width', 'height'});
    return SizeMm(
      width: jsonNumber(map, 'width'),
      height: jsonNumber(map, 'height'),
    );
  }
  static const a3Landscape = SizeMm(width: 420, height: 297);
  static const a4Landscape = SizeMm(width: 297, height: 210);
}

class RectUnits {
  const RectUnits({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });
  final double x;
  final double y;
  final double width;
  final double height;
  RectUnits copyWith({double? x, double? y, double? width, double? height}) =>
      RectUnits(
        x: x ?? this.x,
        y: y ?? this.y,
        width: width ?? this.width,
        height: height ?? this.height,
      );
  Map<String, Object?> toJson() => {
    'x': x,
    'y': y,
    'width': width,
    'height': height,
  };
  factory RectUnits.fromJson(Object? value) {
    final map = jsonObject(
      value,
      'RectUnits',
      allowed: const {'x', 'y', 'width', 'height'},
    );
    return RectUnits(
      x: jsonNumber(map, 'x'),
      y: jsonNumber(map, 'y'),
      width: jsonNumber(map, 'width'),
      height: jsonNumber(map, 'height'),
    );
  }
  Vec2 get topLeft => Vec2(x, y);
}

class Article {
  const Article({
    required this.id,
    required this.name,
    required this.unit,
    this.manufacturer,
    this.partNumber,
    this.specification = '',
    this.dimensionsMm,
    this.note = '',
    this.sourceUrl,
  });
  final String id;
  final String name;
  final QuantityUnit unit;
  final String? manufacturer;
  final String? partNumber;
  final String specification;
  final DimensionsMm? dimensionsMm;
  final String note;
  final String? sourceUrl;
  Article copyWith({
    String? id,
    String? name,
    QuantityUnit? unit,
    Object? manufacturer = unchanged,
    Object? partNumber = unchanged,
    String? specification,
    Object? dimensionsMm = unchanged,
    String? note,
    Object? sourceUrl = unchanged,
  }) => Article(
    id: id ?? this.id,
    name: name ?? this.name,
    unit: unit ?? this.unit,
    manufacturer:
        identical(manufacturer, unchanged)
            ? this.manufacturer
            : manufacturer as String?,
    partNumber:
        identical(partNumber, unchanged)
            ? this.partNumber
            : partNumber as String?,
    specification: specification ?? this.specification,
    dimensionsMm:
        identical(dimensionsMm, unchanged)
            ? this.dimensionsMm
            : dimensionsMm as DimensionsMm?,
    note: note ?? this.note,
    sourceUrl:
        identical(sourceUrl, unchanged) ? this.sourceUrl : sourceUrl as String?,
  );
  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'unit': unit.name,
    if (manufacturer != null) 'manufacturer': manufacturer,
    if (partNumber != null) 'partNumber': partNumber,
    'specification': specification,
    if (dimensionsMm != null) 'dimensionsMm': dimensionsMm!.toJson(),
    'note': note,
    if (sourceUrl != null) 'sourceUrl': sourceUrl,
  };
  factory Article.fromJson(Object? value) {
    final map = jsonObject(
      value,
      'Article',
      allowed: const {
        'id',
        'name',
        'unit',
        'manufacturer',
        'partNumber',
        'specification',
        'dimensionsMm',
        'note',
        'sourceUrl',
      },
    );
    return Article(
      id: jsonString(map, 'id', max: 128),
      name: jsonString(map, 'name', max: 200),
      unit: jsonEnum(map, 'unit', QuantityUnit.values),
      manufacturer:
          map['manufacturer'] == null
              ? null
              : jsonString(map, 'manufacturer', max: 200),
      partNumber:
          map['partNumber'] == null
              ? null
              : jsonString(map, 'partNumber', max: 200),
      specification: jsonString(map, 'specification', max: 8192, fallback: ''),
      dimensionsMm:
          map['dimensionsMm'] == null
              ? null
              : DimensionsMm.fromJson(map['dimensionsMm']),
      note: jsonString(map, 'note', max: 8192, fallback: ''),
      sourceUrl:
          map['sourceUrl'] == null
              ? null
              : jsonString(map, 'sourceUrl', max: 2048),
    );
  }
}

class Procurement {
  const Procurement({
    this.source = ProcurementSource.purchase,
    this.includedInComponentId,
  });
  final ProcurementSource source;
  final String? includedInComponentId;
  Procurement copyWith({
    ProcurementSource? source,
    Object? includedInComponentId = unchanged,
  }) => Procurement(
    source: source ?? this.source,
    includedInComponentId:
        identical(includedInComponentId, unchanged)
            ? this.includedInComponentId
            : includedInComponentId as String?,
  );
  Map<String, Object?> toJson() => {
    'source': source.name,
    if (includedInComponentId != null)
      'includedInComponentId': includedInComponentId,
  };
  factory Procurement.fromJson(Object? value) {
    final map = jsonObject(
      value,
      'Procurement',
      allowed: const {'source', 'includedInComponentId'},
    );
    return Procurement(
      source: jsonEnum(map, 'source', ProcurementSource.values),
      includedInComponentId:
          map['includedInComponentId'] == null
              ? null
              : jsonString(map, 'includedInComponentId', max: 128),
    );
  }
}

class ComponentTerminal {
  const ComponentTerminal({
    required this.id,
    required this.designation,
    this.signal = '',
  });
  final String id;
  final String designation;
  final String signal;
  ComponentTerminal copyWith({
    String? id,
    String? designation,
    String? signal,
  }) => ComponentTerminal(
    id: id ?? this.id,
    designation: designation ?? this.designation,
    signal: signal ?? this.signal,
  );
  Map<String, Object?> toJson() => {
    'id': id,
    'designation': designation,
    'signal': signal,
  };
  factory ComponentTerminal.fromJson(Object? value) {
    final map = jsonObject(
      value,
      'ComponentTerminal',
      allowed: const {'id', 'designation', 'signal'},
    );
    return ComponentTerminal(
      id: jsonString(map, 'id', max: 128),
      designation: jsonString(map, 'designation', max: 64),
      signal: jsonString(map, 'signal', max: 200, fallback: ''),
    );
  }
}

class ComponentFunction {
  ComponentFunction({
    required this.id,
    required this.name,
    List<String> terminalIds = const [],
  }) : terminalIds = List.unmodifiable(terminalIds);
  final String id;
  final String name;
  final List<String> terminalIds;
  ComponentFunction copyWith({
    String? id,
    String? name,
    List<String>? terminalIds,
  }) => ComponentFunction(
    id: id ?? this.id,
    name: name ?? this.name,
    terminalIds: terminalIds ?? this.terminalIds,
  );
  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'terminalIds': terminalIds,
  };
  factory ComponentFunction.fromJson(Object? value) {
    final map = jsonObject(
      value,
      'ComponentFunction',
      allowed: const {'id', 'name', 'terminalIds'},
    );
    return ComponentFunction(
      id: jsonString(map, 'id', max: 128),
      name: jsonString(map, 'name', max: 200),
      terminalIds:
          jsonList(
            map,
            'terminalIds',
            max: 256,
          ).map((v) => jsonString({'value': v}, 'value', max: 128)).toList(),
    );
  }
}

class ElectricalModel {
  ElectricalModel({
    List<ComponentTerminal> terminals = const [],
    List<ComponentFunction> functions = const [],
  }) : terminals = List.unmodifiable(terminals),
       functions = List.unmodifiable(functions);
  final List<ComponentTerminal> terminals;
  final List<ComponentFunction> functions;
  ElectricalModel copyWith({
    List<ComponentTerminal>? terminals,
    List<ComponentFunction>? functions,
  }) => ElectricalModel(
    terminals: terminals ?? this.terminals,
    functions: functions ?? this.functions,
  );
  Map<String, Object?> toJson() => {
    'terminals': terminals.map((v) => v.toJson()).toList(),
    'functions': functions.map((v) => v.toJson()).toList(),
  };
  factory ElectricalModel.fromJson(Object? value) {
    final map = jsonObject(
      value,
      'ElectricalModel',
      allowed: const {'terminals', 'functions'},
    );
    return ElectricalModel(
      terminals:
          jsonList(
            map,
            'terminals',
            max: 256,
          ).map(ComponentTerminal.fromJson).toList(),
      functions:
          jsonList(
            map,
            'functions',
            max: 64,
          ).map(ComponentFunction.fromJson).toList(),
    );
  }
  ComponentTerminal? terminalById(String id) =>
      findById(terminals, id, (v) => v.id);
  ComponentFunction? functionById(String id) =>
      findById(functions, id, (v) => v.id);
}

class Component {
  const Component({
    required this.id,
    this.kind = ComponentKind.physical,
    String? designation,
    this.reference,
    this.terminal,
    this.description = '',
    this.articleId,
    this.quantity = const Quantity.pieces(1),
    this.usage = ComponentUsage.installed,
    this.procurement = const Procurement(),
    this.location = '',
    this.electrical,
    this.mountingSizeOverrideMm,
    this.note = '',
  }) : _legacyDesignation = designation;
  final String id;
  final ComponentKind kind;
  final String? _legacyDesignation;
  String? get legacyDesignation => _legacyDesignation;
  String? get designation => reference?.full ?? _legacyDesignation;
  final ComponentReference? reference;
  final TerminalAssignment? terminal;
  final String description;
  final String? articleId;
  final Quantity quantity;
  final ComponentUsage usage;
  final Procurement procurement;
  final String location;
  final ElectricalModel? electrical;
  final DimensionsMm? mountingSizeOverrideMm;
  final String note;
  Component copyWith({
    String? id,
    ComponentKind? kind,
    Object? designation = unchanged,
    Object? reference = unchanged,
    Object? terminal = unchanged,
    String? description,
    Object? articleId = unchanged,
    Quantity? quantity,
    ComponentUsage? usage,
    Procurement? procurement,
    String? location,
    Object? electrical = unchanged,
    Object? mountingSizeOverrideMm = unchanged,
    String? note,
  }) => Component(
    id: id ?? this.id,
    kind: kind ?? this.kind,
    designation:
        identical(designation, unchanged)
            ? _legacyDesignation
            : designation as String?,
    reference:
        identical(reference, unchanged)
            ? this.reference
            : reference as ComponentReference?,
    terminal:
        identical(terminal, unchanged)
            ? this.terminal
            : terminal as TerminalAssignment?,
    description: description ?? this.description,
    articleId:
        identical(articleId, unchanged) ? this.articleId : articleId as String?,
    quantity: quantity ?? this.quantity,
    usage: usage ?? this.usage,
    procurement: procurement ?? this.procurement,
    location: location ?? this.location,
    electrical:
        identical(electrical, unchanged)
            ? this.electrical
            : electrical as ElectricalModel?,
    mountingSizeOverrideMm:
        identical(mountingSizeOverrideMm, unchanged)
            ? this.mountingSizeOverrideMm
            : mountingSizeOverrideMm as DimensionsMm?,
    note: note ?? this.note,
  );
  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind.name,
    if (_legacyDesignation != null) 'designation': _legacyDesignation,
    if (reference != null) 'reference': reference!.toJson(),
    if (terminal != null) 'terminal': terminal!.toJson(),
    'description': description,
    if (articleId != null) 'articleId': articleId,
    'quantity': quantity.toJson(),
    'usage': usage.name,
    'procurement': procurement.toJson(),
    'location': location,
    if (electrical != null) 'electrical': electrical!.toJson(),
    if (mountingSizeOverrideMm != null)
      'mountingSizeOverrideMm': mountingSizeOverrideMm!.toJson(),
    'note': note,
  };
  factory Component.fromJson(Object? value) {
    final map = jsonObject(
      value,
      'Component',
      allowed: const {
        'id',
        'kind',
        'designation',
        'reference',
        'terminal',
        'description',
        'articleId',
        'quantity',
        'usage',
        'procurement',
        'location',
        'electrical',
        'mountingSizeOverrideMm',
        'note',
      },
    );
    return Component(
      id: jsonString(map, 'id', max: 128),
      kind: jsonEnum(map, 'kind', ComponentKind.values),
      reference:
          map['reference'] == null
              ? null
              : ComponentReference.fromJson(map['reference']),
      terminal:
          map['terminal'] == null
              ? null
              : TerminalAssignment.fromJson(map['terminal']),
      designation:
          map['designation'] == null
              ? null
              : jsonString(map, 'designation', max: 64),
      description: jsonString(map, 'description', max: 8192, fallback: ''),
      articleId:
          map['articleId'] == null
              ? null
              : jsonString(map, 'articleId', max: 128),
      quantity: Quantity.fromJson(map['quantity']),
      usage: jsonEnum(map, 'usage', ComponentUsage.values),
      procurement: Procurement.fromJson(map['procurement']),
      location: jsonString(map, 'location', max: 200, fallback: ''),
      electrical:
          map['electrical'] == null
              ? null
              : ElectricalModel.fromJson(map['electrical']),
      mountingSizeOverrideMm:
          map['mountingSizeOverrideMm'] == null
              ? null
              : DimensionsMm.fromJson(map['mountingSizeOverrideMm']),
      note: jsonString(map, 'note', max: 8192, fallback: ''),
    );
  }
}

class BuiltinSymbolSpec extends SymbolSpec {
  BuiltinSymbolSpec({
    required this.kind,
    Map<String, String> bindings = const {},
  }) : bindings = Map.unmodifiable(bindings);
  final DeviceKind kind;
  final Map<String, String> bindings;
  BuiltinSymbolSpec copyWith({
    DeviceKind? kind,
    Map<String, String>? bindings,
  }) => BuiltinSymbolSpec(
    kind: kind ?? this.kind,
    bindings: bindings ?? this.bindings,
  );
  @override
  Map<String, Object?> toJson() => {
    'type': 'builtin',
    'kind': kind.name,
    'bindings': bindings,
  };
  factory BuiltinSymbolSpec.fromJson(Object? value) {
    final map = jsonObject(
      value,
      'BuiltinSymbolSpec',
      allowed: const {'kind', 'bindings', 'type'},
    );
    if (map['type'] != 'builtin')
      throw const EcadException(
        'Invalid symbol discriminator.',
        code: 'invalid_schema',
      );
    return BuiltinSymbolSpec(
      kind: jsonEnum(map, 'kind', DeviceKind.values),
      bindings: jsonStringMap(map['bindings'], 256),
    );
  }
}

class TerminalSymbolSpec extends SymbolSpec {
  TerminalSymbolSpec({
    required this.terminalId,
    Set<PortSide> sides = const {PortSide.top, PortSide.bottom},
  }) : sides = Set.unmodifiable(sides) {
    if (sides.isEmpty) {
      throw const EcadException(
        'A terminal requires at least one connection direction.',
        code: 'invalid_terminal_symbol',
      );
    }
  }
  final String terminalId;
  final Set<PortSide> sides;
  TerminalSymbolSpec copyWith({String? terminalId, Set<PortSide>? sides}) =>
      TerminalSymbolSpec(
        terminalId: terminalId ?? this.terminalId,
        sides: sides ?? this.sides,
      );
  @override
  Map<String, Object?> toJson() => {
    'type': 'terminal',
    'terminalId': terminalId,
    'sides': [
      for (final side in PortSide.values)
        if (sides.contains(side)) side.name,
    ],
  };
  factory TerminalSymbolSpec.fromJson(Object? value) {
    final map = jsonObject(
      value,
      'TerminalSymbolSpec',
      allowed: const {'type', 'terminalId', 'sides'},
    );
    if (map['type'] != 'terminal') {
      throw const EcadException(
        'Invalid symbol discriminator.',
        code: 'invalid_schema',
      );
    }
    final raw = jsonList(map, 'sides', max: 4);
    final sides = <PortSide>{};
    for (final value in raw) {
      final side = PortSide.values.where((s) => s.name == value).firstOrNull;
      if (side == null || !sides.add(side)) {
        throw const EcadException(
          'Terminal directions must be distinct valid sides.',
          code: 'invalid_terminal_symbol',
        );
      }
    }
    return TerminalSymbolSpec(
      terminalId: jsonString(map, 'terminalId', max: 128),
      sides: sides,
    );
  }
}

class BlockPort {
  const BlockPort({
    required this.id,
    required this.terminalId,
    required this.side,
    required this.fraction,
  });
  final String id;
  final String terminalId;
  final PortSide side;
  final double fraction;
  BlockPort copyWith({
    String? id,
    String? terminalId,
    PortSide? side,
    double? fraction,
  }) => BlockPort(
    id: id ?? this.id,
    terminalId: terminalId ?? this.terminalId,
    side: side ?? this.side,
    fraction: fraction ?? this.fraction,
  );
  Map<String, Object?> toJson() => {
    'id': id,
    'terminalId': terminalId,
    'side': side.name,
    'fraction': fraction,
  };
  factory BlockPort.fromJson(Object? value) {
    final map = jsonObject(
      value,
      'BlockPort',
      allowed: const {'id', 'terminalId', 'side', 'fraction'},
    );
    return BlockPort(
      id: jsonString(map, 'id', max: 128),
      terminalId: jsonString(map, 'terminalId', max: 128),
      side: jsonEnum(map, 'side', PortSide.values),
      fraction: jsonNumber(map, 'fraction'),
    );
  }
}

class PortBlockSpec extends SymbolSpec {
  PortBlockSpec({
    required this.width,
    required this.height,
    List<BlockPort> ports = const [],
  }) : ports = List.unmodifiable(ports);
  final double width;
  final double height;
  final List<BlockPort> ports;
  PortBlockSpec copyWith({
    double? width,
    double? height,
    List<BlockPort>? ports,
  }) => PortBlockSpec(
    width: width ?? this.width,
    height: height ?? this.height,
    ports: ports ?? this.ports,
  );
  @override
  Map<String, Object?> toJson() => {
    'type': 'block',
    'width': width,
    'height': height,
    'ports': ports.map((v) => v.toJson()).toList(),
  };
  factory PortBlockSpec.fromJson(Object? value) {
    final map = jsonObject(
      value,
      'PortBlockSpec',
      allowed: const {'width', 'height', 'ports', 'type'},
    );
    if (map['type'] != 'block')
      throw const EcadException(
        'Invalid symbol discriminator.',
        code: 'invalid_schema',
      );
    return PortBlockSpec(
      width: jsonNumber(map, 'width'),
      height: jsonNumber(map, 'height'),
      ports: jsonList(map, 'ports', max: 256).map(BlockPort.fromJson).toList(),
    );
  }
}

class ContinuationLink {
  const ContinuationLink({required this.id, required this.label});
  final String id;
  final String label;
  ContinuationLink copyWith({String? id, String? label}) =>
      ContinuationLink(id: id ?? this.id, label: label ?? this.label);
  Map<String, Object?> toJson() => {'id': id, 'label': label};
  factory ContinuationLink.fromJson(Object? value) {
    final map = jsonObject(
      value,
      'ContinuationLink',
      allowed: const {'id', 'label'},
    );
    return ContinuationLink(
      id: jsonString(map, 'id', max: 128),
      label: jsonString(map, 'label', max: 200),
    );
  }
}

class ContinuationMarker {
  const ContinuationMarker({
    required this.id,
    required this.linkId,
    required this.position,
    this.direction = PortSide.left,
    this.glyph = ContinuationGlyph.arrow,
  });
  final String id;
  final String linkId;
  final Vec2 position;
  final PortSide direction;
  final ContinuationGlyph glyph;
  ContinuationMarker copyWith({
    String? id,
    String? linkId,
    Vec2? position,
    PortSide? direction,
    ContinuationGlyph? glyph,
  }) => ContinuationMarker(
    id: id ?? this.id,
    linkId: linkId ?? this.linkId,
    position: position ?? this.position,
    direction: direction ?? this.direction,
    glyph: glyph ?? this.glyph,
  );
  Map<String, Object?> toJson() => {
    'id': id,
    'linkId': linkId,
    'position': position.toJson(),
    'direction': direction.name,
    'glyph': glyph.name,
  };
  factory ContinuationMarker.fromJson(Object? value) {
    final map = jsonObject(
      value,
      'ContinuationMarker',
      allowed: const {'id', 'linkId', 'position', 'direction', 'glyph'},
    );
    return ContinuationMarker(
      id: jsonString(map, 'id', max: 128),
      linkId: jsonString(map, 'linkId', max: 128),
      position: Vec2.fromJson(map['position']),
      direction: jsonEnum(map, 'direction', PortSide.values),
      glyph: jsonEnum(map, 'glyph', ContinuationGlyph.values),
    );
  }
}

class MountingPlacement {
  const MountingPlacement({
    required this.id,
    required this.componentId,
    required this.centerMm,
    this.rotation = 0,
  });
  final String id;
  final String componentId;
  final Vec2 centerMm;
  final double rotation;
  MountingPlacement copyWith({
    String? id,
    String? componentId,
    Vec2? centerMm,
    double? rotation,
  }) => MountingPlacement(
    id: id ?? this.id,
    componentId: componentId ?? this.componentId,
    centerMm: centerMm ?? this.centerMm,
    rotation: rotation ?? this.rotation,
  );
  Map<String, Object?> toJson() => {
    'id': id,
    'componentId': componentId,
    'centerMm': centerMm.toJson(),
    'rotation': rotation,
  };
  factory MountingPlacement.fromJson(Object? value) {
    final map = jsonObject(
      value,
      'MountingPlacement',
      allowed: const {'id', 'componentId', 'centerMm', 'rotation'},
    );
    return MountingPlacement(
      id: jsonString(map, 'id', max: 128),
      componentId: jsonString(map, 'componentId', max: 128),
      centerMm: Vec2.fromJson(map['centerMm']),
      rotation: jsonNumber(map, 'rotation', fallback: 0),
    );
  }
}

class MountingLayout {
  MountingLayout({
    required this.id,
    required this.name,
    this.surfaceComponentId,
    required this.widthMm,
    required this.heightMm,
    List<MountingPlacement> placements = const [],
  }) : placements = List.unmodifiable(placements);
  final String id;
  final String name;
  final String? surfaceComponentId;
  final double widthMm;
  final double heightMm;
  final List<MountingPlacement> placements;
  MountingLayout copyWith({
    String? id,
    String? name,
    Object? surfaceComponentId = unchanged,
    double? widthMm,
    double? heightMm,
    List<MountingPlacement>? placements,
  }) => MountingLayout(
    id: id ?? this.id,
    name: name ?? this.name,
    surfaceComponentId:
        identical(surfaceComponentId, unchanged)
            ? this.surfaceComponentId
            : surfaceComponentId as String?,
    widthMm: widthMm ?? this.widthMm,
    heightMm: heightMm ?? this.heightMm,
    placements: placements ?? this.placements,
  );
  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    if (surfaceComponentId != null) 'surfaceComponentId': surfaceComponentId,
    'widthMm': widthMm,
    'heightMm': heightMm,
    'placements': placements.map((v) => v.toJson()).toList(),
  };
  factory MountingLayout.fromJson(Object? value) {
    final map = jsonObject(
      value,
      'MountingLayout',
      allowed: const {
        'id',
        'name',
        'surfaceComponentId',
        'widthMm',
        'heightMm',
        'placements',
      },
    );
    return MountingLayout(
      id: jsonString(map, 'id', max: 128),
      name: jsonString(map, 'name', max: 200),
      surfaceComponentId:
          map['surfaceComponentId'] == null
              ? null
              : jsonString(map, 'surfaceComponentId', max: 128),
      widthMm: jsonNumber(map, 'widthMm'),
      heightMm: jsonNumber(map, 'heightMm'),
      placements:
          jsonList(
            map,
            'placements',
            max: 20000,
          ).map(MountingPlacement.fromJson).toList(),
    );
  }
}

class MountingView {
  const MountingView({
    required this.layoutId,
    this.originMm = Vec2.zero,
    required this.viewport,
    this.scaleDenominator = 1,
    this.showSurfaceDimensions = true,
    this.showComponentDimensions = false,
  });
  final String layoutId;
  final Vec2 originMm;
  final RectUnits viewport;
  final double scaleDenominator;
  final bool showSurfaceDimensions;
  final bool showComponentDimensions;
  MountingView copyWith({
    String? layoutId,
    Vec2? originMm,
    RectUnits? viewport,
    double? scaleDenominator,
    bool? showSurfaceDimensions,
    bool? showComponentDimensions,
  }) => MountingView(
    layoutId: layoutId ?? this.layoutId,
    originMm: originMm ?? this.originMm,
    viewport: viewport ?? this.viewport,
    scaleDenominator: scaleDenominator ?? this.scaleDenominator,
    showSurfaceDimensions: showSurfaceDimensions ?? this.showSurfaceDimensions,
    showComponentDimensions:
        showComponentDimensions ?? this.showComponentDimensions,
  );
  Map<String, Object?> toJson() => {
    'layoutId': layoutId,
    'originMm': originMm.toJson(),
    'viewport': viewport.toJson(),
    'scaleDenominator': scaleDenominator,
    'showSurfaceDimensions': showSurfaceDimensions,
    'showComponentDimensions': showComponentDimensions,
  };
  factory MountingView.fromJson(Object? value) {
    final map = jsonObject(
      value,
      'MountingView',
      allowed: const {
        'layoutId',
        'originMm',
        'viewport',
        'scaleDenominator',
        'showSurfaceDimensions',
        'showComponentDimensions',
      },
    );
    return MountingView(
      layoutId: jsonString(map, 'layoutId', max: 128),
      originMm: Vec2.fromJson(map['originMm']),
      viewport: RectUnits.fromJson(map['viewport']),
      scaleDenominator: jsonNumber(map, 'scaleDenominator', fallback: 1),
      showSurfaceDimensions: jsonBool(
        map,
        'showSurfaceDimensions',
        fallback: true,
      ),
      showComponentDimensions: jsonBool(
        map,
        'showComponentDimensions',
        fallback: false,
      ),
    );
  }
}

class BomTableSpec {
  const BomTableSpec({required this.kind, this.title = '', this.note = ''});
  final BomReportKind kind;
  final String title;
  final String note;
  BomTableSpec copyWith({BomReportKind? kind, String? title, String? note}) =>
      BomTableSpec(
        kind: kind ?? this.kind,
        title: title ?? this.title,
        note: note ?? this.note,
      );
  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'title': title,
    'note': note,
  };
  factory BomTableSpec.fromJson(Object? value) {
    final map = jsonObject(
      value,
      'BomTableSpec',
      allowed: const {'kind', 'title', 'note'},
    );
    return BomTableSpec(
      kind: jsonEnum(map, 'kind', BomReportKind.values),
      title: jsonString(map, 'title', max: 200, fallback: ''),
      note: jsonString(map, 'note', max: 8192, fallback: ''),
    );
  }
}

class Device {
  const Device({
    required this.id,
    required this.componentId,
    required this.functionId,
    required this.symbol,
    required this.position,
    this.rotation = 0,
    this.mode = OccurrenceMode.wiring,
    this.isMainFunction = false,
  });
  final String id;
  final String componentId;
  final String functionId;
  final SymbolSpec symbol;
  final Vec2 position;
  final double rotation;
  final OccurrenceMode mode;
  final bool isMainFunction;
  Device copyWith({
    String? id,
    String? componentId,
    String? functionId,
    SymbolSpec? symbol,
    Vec2? position,
    double? rotation,
    OccurrenceMode? mode,
    bool? isMainFunction,
  }) => Device(
    id: id ?? this.id,
    componentId: componentId ?? this.componentId,
    functionId: functionId ?? this.functionId,
    symbol: symbol ?? this.symbol,
    position: position ?? this.position,
    rotation: rotation ?? this.rotation,
    mode: mode ?? this.mode,
    isMainFunction: isMainFunction ?? this.isMainFunction,
  );
  Map<String, Object?> toJson() => {
    'id': id,
    'componentId': componentId,
    'functionId': functionId,
    'symbol': symbol.toJson(),
    'position': position.toJson(),
    'rotation': rotation,
    'mode': mode.name,
    'isMainFunction': isMainFunction,
  };
  factory Device.fromJson(Object? value) {
    final map = jsonObject(
      value,
      'Device',
      allowed: const {
        'id',
        'componentId',
        'functionId',
        'symbol',
        'position',
        'rotation',
        'mode',
        'isMainFunction',
      },
    );
    return Device(
      id: jsonString(map, 'id', max: 128),
      componentId: jsonString(map, 'componentId', max: 128),
      functionId: jsonString(map, 'functionId', max: 128),
      symbol: SymbolSpec.fromJson(map['symbol']),
      position: Vec2.fromJson(map['position']),
      rotation: jsonNumber(map, 'rotation', fallback: 0),
      mode: jsonEnum(map, 'mode', OccurrenceMode.values),
      isMainFunction: jsonBool(map, 'isMainFunction', fallback: false),
    );
  }
  DeviceKind? get kind => switch (symbol) {
    BuiltinSymbolSpec(:final kind) => kind,
    TerminalSymbolSpec() => DeviceKind.terminal,
    PortBlockSpec() => null,
  };
}

Map<String, String> jsonStringMap(Object? value, int max) {
  final map = jsonObject(value, 'bindings');
  if (map.length > max)
    throw const EcadException('Too many bindings.', code: 'limit_exceeded');
  return map.map(
    (k, v) => MapEntry(
      jsonString({'key': k}, 'key', max: 128),
      jsonString({'value': v}, 'value', max: 128),
    ),
  );
}

T? findById<T>(Iterable<T> values, String id, String Function(T) key) {
  for (final value in values) {
    if (key(value) == id) return value;
  }
  return null;
}
