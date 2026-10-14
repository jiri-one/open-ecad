// SPDX-License-Identifier: GPL-3.0-or-later
import 'catalog.dart';
import 'graphics.dart';
import 'model.dart';

enum DiagnosticSeverity { info, warning, error }

class Diagnostic {
  const Diagnostic({
    required this.severity,
    required this.code,
    required this.message,
    this.sheetId,
    this.deviceId,
    this.wireId,
    this.graphicId,
  });
  final DiagnosticSeverity severity;
  final String code;
  final String message;
  final String? sheetId;
  final String? deviceId;
  final String? wireId;
  final String? graphicId;

  Map<String, Object?> toJson() => {
    'severity': severity.name,
    'code': code,
    'message': message,
    if (sheetId != null) 'sheetId': sheetId,
    if (deviceId != null) 'deviceId': deviceId,
    if (wireId != null) 'wireId': wireId,
    if (graphicId != null) 'graphicId': graphicId,
  };
  @override
  String toString() => '${severity.name}: $message';
}

abstract final class ProjectValidator {
  static List<Diagnostic> validate(EcadProject project) =>
      validateProject(project);
}

/// Checks document integrity and connectivity; does not evaluate electrical
/// protection, conductor sizing, regulatory compliance, or physical safety.
List<Diagnostic> validateProject(EcadProject project) {
  final diagnostics = <Diagnostic>[];
  void add(
    String code,
    String message, {
    DiagnosticSeverity severity = DiagnosticSeverity.error,
    String? sheetId,
    String? deviceId,
    String? wireId,
    String? graphicId,
  }) {
    diagnostics.add(
      Diagnostic(
        severity: severity,
        code: code,
        message: message,
        sheetId: sheetId,
        deviceId: deviceId,
        wireId: wireId,
        graphicId: graphicId,
      ),
    );
  }

  final ids = <String>{};
  final identifierPattern = RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_.:-]{0,127}$');
  void id(
    String value,
    String entity, {
    String? sheetId,
    String? deviceId,
    String? wireId,
    String? graphicId,
  }) {
    if (!identifierPattern.hasMatch(value)) {
      add(
        'invalid_id',
        '$entity has an invalid identifier.',
        sheetId: sheetId,
        deviceId: deviceId,
        wireId: wireId,
        graphicId: graphicId,
      );
    }
    if (!ids.add(value)) {
      add(
        'duplicate_id',
        'Identifier "$value" is used more than once.',
        sheetId: sheetId,
        deviceId: deviceId,
        wireId: wireId,
        graphicId: graphicId,
      );
    }
  }

  bool textValid(String value, int max) =>
      value.length <= max && !value.contains('\u0000');
  bool pointValid(Vec2 p) =>
      p.x.isFinite &&
      p.y.isFinite &&
      p.x.abs() <= ProjectLimits.maxCoordinate &&
      p.y.abs() <= ProjectLimits.maxCoordinate;
  id(project.id, 'Project');
  if (!textValid(project.name, 200) ||
      project.name.trim().isEmpty ||
      !textValid(project.description, 8192)) {
    add(
      'invalid_metadata',
      'Project requires a name of at most 200 characters and a description of at most 8192 characters.',
    );
  }
  if (project.revision < 0 || project.revision > ProjectLimits.maxRevision) {
    add('invalid_revision', 'Project revision is out of range.');
  }
  if (project.pages.isEmpty || project.pages.length > ProjectLimits.maxPages) {
    add(
      'invalid_page_count',
      'A project requires 1–${ProjectLimits.maxPages} sheets.',
    );
  }
  if (project.pages.fold<int>(0, (n, p) => n + p.devices.length) >
          ProjectLimits.maxDevices ||
      project.pages.fold<int>(0, (n, p) => n + p.wires.length) >
          ProjectLimits.maxWires ||
      project.pages.fold<int>(0, (n, p) => n + p.graphics.length) >
          ProjectLimits.maxGraphics) {
    add(
      'limit_exceeded',
      'Project exceeds the supported device, wire, or drawing element count.',
    );
    return List.unmodifiable(diagnostics);
  }

  final designations = <String, String>{};
  final sheetNumbers = <String>{};
  var pathSegmentCount = 0;
  var imageCharCount = 0;
  for (final sheet in project.pages) {
    id(sheet.id, 'Sheet', sheetId: sheet.id);
    if (!sheet.width.isFinite ||
        !sheet.height.isFinite ||
        sheet.width <= 0 ||
        sheet.height <= 0 ||
        sheet.width > ProjectLimits.maxCoordinate ||
        sheet.height > ProjectLimits.maxCoordinate) {
      add(
        'invalid_geometry',
        'Sheet width and height must be positive and within the coordinate limits.',
        sheetId: sheet.id,
      );
    }
    if (sheet.sourcePage != null &&
        (sheet.sourcePage! < 1 || sheet.sourcePage! > ProjectLimits.maxPages)) {
      add(
        'invalid_metadata',
        'Source page must be between 1 and ${ProjectLimits.maxPages}.',
        sheetId: sheet.id,
      );
    }
    if (!textValid(sheet.name, 200) ||
        sheet.name.trim().isEmpty ||
        !textValid(sheet.number, 32) ||
        sheet.number.trim().isEmpty) {
      add(
        'invalid_metadata',
        'Sheet requires a name and a number within the format limits.',
        sheetId: sheet.id,
      );
    }
    if (!sheetNumbers.add(sheet.number.trim().toLowerCase())) {
      add(
        'duplicate_sheet_number',
        'Sheet number "${sheet.number}" is repeated.',
        severity: DiagnosticSeverity.warning,
        sheetId: sheet.id,
      );
    }
    for (final graphic in sheet.graphics) {
      id(
        graphic.id,
        'Drawing element',
        sheetId: sheet.id,
        graphicId: graphic.id,
      );
      pathSegmentCount += graphic.path.length;
      imageCharCount += graphic.imageData.length;
      if (pathSegmentCount > ProjectLimits.maxTotalPathSegments ||
          imageCharCount > ProjectLimits.maxTotalImageBase64Chars) {
        add(
          'limit_exceeded',
          'Project exceeds the path segment or embedded image limit.',
          sheetId: sheet.id,
          graphicId: graphic.id,
        );
        return List.unmodifiable(diagnostics);
      }
      try {
        requireValidDrawingElement(graphic);
      } on EcadException catch (error) {
        add(
          error.code,
          error.message,
          sheetId: sheet.id,
          graphicId: graphic.id,
        );
      }
    }
    final devices = <String, Device>{};
    for (final device in sheet.devices) {
      id(device.id, 'Device', sheetId: sheet.id, deviceId: device.id);
      devices[device.id] = device;
      if (!pointValid(device.position) ||
          !device.rotation.isFinite ||
          device.rotation.abs() > ProjectLimits.maxCoordinate) {
        add(
          'invalid_geometry',
          '${device.designation} has an invalid position or rotation.',
          sheetId: sheet.id,
          deviceId: device.id,
        );
      }
      if (!textValid(device.designation, 64) ||
          !textValid(device.description, 8192) ||
          !textValid(device.rating, 128)) {
        add(
          'invalid_metadata',
          'Device text exceeds the format limits.',
          sheetId: sheet.id,
          deviceId: device.id,
        );
      }
      final designation = device.designation.trim().toLowerCase();
      if (designation.isEmpty) {
        add(
          'missing_designation',
          'An unnamed ${definitionFor(device.kind).label.toLowerCase()} needs a designation.',
          severity: DiagnosticSeverity.warning,
          sheetId: sheet.id,
          deviceId: device.id,
        );
      } else if (designations.containsKey(designation)) {
        add(
          'duplicate_designation',
          'Designation "${device.designation}" is repeated; cross-references are not modeled.',
          severity: DiagnosticSeverity.warning,
          sheetId: sheet.id,
          deviceId: device.id,
        );
      } else {
        designations[designation] = device.id;
      }
    }
    final connected = <TerminalRef>{};
    final connections = <String>{};
    for (final wire in sheet.wires) {
      id(wire.id, 'Wire', sheetId: sheet.id, wireId: wire.id);
      if (wire.waypoints.length > ProjectLimits.maxWaypoints ||
          wire.waypoints.any((p) => !pointValid(p))) {
        add(
          'invalid_geometry',
          'Wire ${wire.id} contains invalid route geometry.',
          sheetId: sheet.id,
          wireId: wire.id,
        );
      }
      if (wire.from == wire.to) {
        add(
          'same_endpoint',
          'Wire ${wire.id} connects a terminal to itself.',
          sheetId: sheet.id,
          wireId: wire.id,
        );
      }
      for (final endpoint in [wire.from, wire.to]) {
        final device = devices[endpoint.deviceId];
        if (device == null) {
          add(
            'missing_device',
            'Wire ${wire.id} references a device that is not on this sheet.',
            sheetId: sheet.id,
            wireId: wire.id,
          );
        } else if (definitionFor(device.kind).portById(endpoint.portId) ==
            null) {
          add(
            'invalid_port',
            'Wire ${wire.id} references unknown port "${endpoint.portId}" on ${device.designation}.',
            sheetId: sheet.id,
            deviceId: device.id,
            wireId: wire.id,
          );
        } else {
          connected.add(endpoint);
        }
      }
      // Length prefixes avoid ambiguous identities if an ID contains a colon.
      String key(TerminalRef p) =>
          '${p.deviceId.length}:${p.deviceId}${p.portId.length}:${p.portId}';
      final pair = [key(wire.from), key(wire.to)]..sort();
      if (!connections.add(pair.join('|'))) {
        add(
          'duplicate_connection',
          'Two wires connect the same pair of terminals.',
          severity: DiagnosticSeverity.warning,
          sheetId: sheet.id,
          wireId: wire.id,
        );
      }
    }
    for (final device in sheet.devices) {
      for (final port in definitionFor(device.kind).ports) {
        if (!connected.contains(
          TerminalRef(deviceId: device.id, portId: port.id),
        )) {
          add(
            'unconnected_port',
            '${device.designation.isEmpty ? device.kind.name : device.designation} terminal ${port.label} is unconnected.',
            severity: DiagnosticSeverity.warning,
            sheetId: sheet.id,
            deviceId: device.id,
          );
        }
      }
    }
  }
  return List.unmodifiable(diagnostics);
}

/// Throws only for structural errors; editorial/connectivity warnings remain
/// valid work-in-progress documents.
void requireValidProject(EcadProject project) {
  final errors =
      validateProject(
        project,
      ).where((d) => d.severity == DiagnosticSeverity.error).toList();
  if (errors.isNotEmpty) {
    throw EcadException(
      errors.take(6).map((e) => e.message).join(' '),
      code: errors.first.code,
    );
  }
}
