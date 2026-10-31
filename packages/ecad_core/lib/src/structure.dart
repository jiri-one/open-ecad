// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'model.dart';

enum StructureAspect { function, location, product }

StructureContext replaceStructurePrefix(
  StructureContext context,
  StructureAspect aspect,
  List<String> prefix,
  List<String> replacement,
) {
  final paths = context.paths;
  final path = paths[aspect.index];
  if (path.length < prefix.length ||
      prefix.indexed.any((v) => path[v.$1] != v.$2))
    return context;
  paths[aspect.index] = [...replacement, ...path.skip(prefix.length)];
  return StructureContext(
    functionPath: paths[0],
    locationPath: paths[1],
    productPath: paths[2],
  );
}

class StructureContext {
  StructureContext({
    List<String> functionPath = const [],
    List<String> locationPath = const [],
    List<String> productPath = const [],
  }) : functionPath = List.unmodifiable(functionPath),
       locationPath = List.unmodifiable(locationPath),
       productPath = List.unmodifiable(productPath);
  const StructureContext.empty()
    : functionPath = const [],
      locationPath = const [],
      productPath = const [];
  final List<String> functionPath, locationPath, productPath;
  bool get isEmpty =>
      functionPath.isEmpty && locationPath.isEmpty && productPath.isEmpty;
  String get prefix =>
      '${functionPath.map((v) => '=$v').join()}${locationPath.map((v) => '+$v').join()}${productPath.map((v) => '-$v').join()}';
  List<List<String>> get paths => [functionPath, locationPath, productPath];
  String get key =>
      jsonEncode(paths.map((p) => p.map(referenceKey).toList()).toList());
  Map<String, Object?> toJson() => {
    'functionPath': functionPath,
    'locationPath': locationPath,
    'productPath': productPath,
  };
  factory StructureContext.fromJson(Object? value) {
    if (value == null) return const StructureContext.empty();
    final map = jsonObject(
      value,
      'StructureContext',
      allowed: const {'functionPath', 'locationPath', 'productPath'},
    );
    List<String> path(String name) =>
        jsonList(
          map,
          name,
          max: 16,
          optional: true,
        ).map((v) => jsonString({'v': v}, 'v', max: 64)).toList();
    return StructureContext(
      functionPath: path('functionPath'),
      locationPath: path('locationPath'),
      productPath: path('productPath'),
    );
  }
  @override
  bool operator ==(Object other) =>
      other is StructureContext &&
      jsonEncode(toJson()) == jsonEncode(other.toJson());
  @override
  int get hashCode => jsonEncode(toJson()).hashCode;
}

class ComponentReference {
  ComponentReference({
    this.context = const StructureContext.empty(),
    required String localDesignation,
  }) : localDesignation = localDesignation.trim().replaceFirst(
         RegExp(r'^-'),
         '',
       );
  final StructureContext context;
  final String localDesignation;
  String get full => '${context.prefix}-$localDesignation';
  String get key => jsonEncode([context.key, referenceKey(localDesignation)]);
  String relativeTo(StructureContext context) =>
      this.context == context ? '-$localDesignation' : full;
  Map<String, Object?> toJson() => {
    'context': context.toJson(),
    'localDesignation': localDesignation,
  };
  factory ComponentReference.fromJson(Object? value) {
    final map = jsonObject(
      value,
      'ComponentReference',
      allowed: const {'context', 'localDesignation'},
    );
    return ComponentReference(
      context: StructureContext.fromJson(map['context']),
      localDesignation: jsonString(map, 'localDesignation', max: 64),
    );
  }
}

class TerminalStrip {
  const TerminalStrip({required this.id, required this.reference});
  final String id;
  final ComponentReference reference;
  TerminalStrip copyWith({ComponentReference? reference}) =>
      TerminalStrip(id: id, reference: reference ?? this.reference);
  Map<String, Object?> toJson() => {'id': id, 'reference': reference.toJson()};
  factory TerminalStrip.fromJson(Object? value) {
    final map = jsonObject(
      value,
      'TerminalStrip',
      allowed: const {'id', 'reference'},
    );
    return TerminalStrip(
      id: jsonString(map, 'id', max: 128),
      reference: ComponentReference.fromJson(map['reference']),
    );
  }
}

class TerminalAssignment {
  TerminalAssignment({
    required this.stripId,
    required this.number,
    Map<String, String> connectionPoints = const {
      'top': '1',
      'bottom': '2',
      'left': '3',
      'right': '4',
    },
  }) : connectionPoints = Map.unmodifiable(connectionPoints);
  final String stripId, number;
  final Map<String, String> connectionPoints;
  TerminalAssignment copyWith({
    String? stripId,
    String? number,
    Map<String, String>? connectionPoints,
  }) => TerminalAssignment(
    stripId: stripId ?? this.stripId,
    number: number ?? this.number,
    connectionPoints: connectionPoints ?? this.connectionPoints,
  );
  Map<String, Object?> toJson() => {
    'stripId': stripId,
    'number': number,
    'connectionPoints': connectionPoints,
  };
  factory TerminalAssignment.fromJson(Object? value) {
    final map = jsonObject(
      value,
      'TerminalAssignment',
      allowed: const {'stripId', 'number', 'connectionPoints'},
    );
    return TerminalAssignment(
      stripId: jsonString(map, 'stripId', max: 128),
      number: jsonString(map, 'number', max: 64),
      connectionPoints: jsonStringMap(map['connectionPoints'], 4),
    );
  }
}

String referenceKey(String value) => value.trim().toLowerCase();
bool validReferenceSegment(String value) =>
    value.isNotEmpty &&
    value == value.trim() &&
    value.length <= 64 &&
    !RegExp(r'[=+\-:&\r\n\x00-\x1f]').hasMatch(value);
bool validStructure(StructureContext value) =>
    value.paths.every((p) => p.length <= 16 && p.every(validReferenceSegment));
String fullPageDesignation(Sheet sheet) =>
    sheet.structure.isEmpty && sheet.documentCode.isEmpty
        ? sheet.number
        : '${sheet.structure.prefix}${sheet.documentCode.isEmpty ? '' : '&${sheet.documentCode}'}/${sheet.number}';
String pageDesignationKey(Sheet sheet) => jsonEncode([
  sheet.structure.key,
  referenceKey(sheet.documentCode),
  referenceKey(sheet.number),
]);

String nextLocalDesignation(
  EcadProject project,
  StructureContext context,
  String prefix,
) {
  final occupied = <String>{};
  final fullDesignations = _occupiedFullDesignations(project);
  for (final c in project.components) {
    if (c.reference case final ref?) {
      if (ref.context.key == context.key)
        occupied.add(referenceKey(ref.localDesignation));
    } else if (context.isEmpty &&
        c.designation != null &&
        RegExp(r'^-?[\w.]+$').hasMatch(c.designation!.trim())) {
      occupied.add(
        referenceKey(c.designation!).replaceFirst(RegExp(r'^-'), ''),
      );
    }
  }
  for (final strip in project.terminalStrips) {
    if (strip.reference.context.key == context.key)
      occupied.add(referenceKey(strip.reference.localDesignation));
  }
  for (var i = 1; ; i++) {
    final local = '$prefix$i';
    final full =
        ComponentReference(context: context, localDesignation: local).full;
    if (!occupied.contains(referenceKey(local)) &&
        !fullDesignations.contains(referenceKey(full)))
      return local;
  }
}

Set<String> _occupiedFullDesignations(EcadProject project) {
  final strips = {for (final strip in project.terminalStrips) strip.id: strip};
  return {
    for (final strip in project.terminalStrips)
      referenceKey(strip.reference.full),
    for (final component in project.components)
      if (component.terminal case final terminal?)
        referenceKey(
          '${strips[terminal.stripId]?.reference.full ?? '?'}:${terminal.number}',
        )
      else if (component.designation case final designation?)
        referenceKey(designation),
  };
}

String nextTerminalNumber(EcadProject project, TerminalStrip strip) {
  final occupied = {
    for (final component in project.components)
      if (component.terminal?.stripId == strip.id)
        referenceKey(component.terminal!.number),
  };
  final fullDesignations = _occupiedFullDesignations(project);
  for (var i = 1; ; i++) {
    final number = '$i';
    if (!occupied.contains(referenceKey(number)) &&
        !fullDesignations.contains(
          referenceKey('${strip.reference.full}:$number'),
        )) {
      return number;
    }
  }
}

String nextPageNumber(EcadProject project, Sheet template) {
  final keys = project.pages.map(pageDesignationKey).toSet();
  final fullDesignations = {
    for (final page in project.pages) referenceKey(fullPageDesignation(page)),
  };
  for (var i = 1; ; i++) {
    final number = i.toString().padLeft(2, '0');
    final candidate = template.copyWith(number: number);
    if (!keys.contains(pageDesignationKey(candidate)) &&
        !fullDesignations.contains(
          referenceKey(fullPageDesignation(candidate)),
        )) {
      return number;
    }
  }
}
