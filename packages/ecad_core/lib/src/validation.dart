// SPDX-License-Identifier: GPL-3.0-or-later
import 'catalog.dart';
import 'graphics.dart';
import 'model.dart';
import 'resolver.dart';

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
    this.componentId,
    this.articleId,
    this.markerId,
    this.layoutId,
  });
  final DiagnosticSeverity severity;
  final String code;
  final String message;
  final String? sheetId;
  final String? deviceId;
  final String? wireId;
  final String? graphicId;
  final String? componentId;
  final String? articleId;
  final String? markerId;
  final String? layoutId;

  Map<String, Object?> toJson() => {
    'severity': severity.name,
    'code': code,
    'message': message,
    if (sheetId != null) 'sheetId': sheetId,
    if (deviceId != null) 'deviceId': deviceId,
    if (wireId != null) 'wireId': wireId,
    if (graphicId != null) 'graphicId': graphicId,
    if (componentId != null) 'componentId': componentId,
    if (articleId != null) 'articleId': articleId,
    if (markerId != null) 'markerId': markerId,
    if (layoutId != null) 'layoutId': layoutId,
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
List<Diagnostic> validateProject(EcadProject project) => List.of(
  _projectDiagnostics[project] ??= List.unmodifiable(
    _Validation(project).run(),
  ),
);

final _projectDiagnostics = Expando<List<Diagnostic>>();

class _Validation {
  _Validation(this.project) : resolver = ProjectResolver(project);
  final EcadProject project;
  final ProjectResolver resolver;
  final diagnostics = <Diagnostic>[];
  final ids = <String>{};
  static final identifier = RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_.:-]{0,127}$');

  void add(
    String code,
    String message, {
    bool warning = false,
    String? sheetId,
    String? deviceId,
    String? componentId,
    String? articleId,
    String? wireId,
    String? graphicId,
    String? markerId,
    String? layoutId,
  }) {
    diagnostics.add(
      Diagnostic(
        severity:
            warning ? DiagnosticSeverity.warning : DiagnosticSeverity.error,
        code: code,
        message: message,
        sheetId: sheetId,
        deviceId: deviceId,
        componentId: componentId,
        articleId: articleId,
        wireId: wireId,
        graphicId: graphicId,
        markerId: markerId,
        layoutId: layoutId,
      ),
    );
  }

  void id(String value) {
    if (!identifier.hasMatch(value))
      add('invalid_id', 'Invalid identifier "$value".');
    if (!ids.add(value))
      add('duplicate_id', 'Identifier "$value" is used more than once.');
  }

  bool text(String value, int max, {bool required = false}) =>
      value.length <= max &&
      !value.contains('\u0000') &&
      (!required || value.trim().isNotEmpty);
  bool positive(double n) =>
      n.isFinite && n > 0 && n <= ProjectLimits.maxCoordinate;
  bool point(Vec2 p) =>
      p.x.isFinite &&
      p.y.isFinite &&
      p.x.abs() <= ProjectLimits.maxCoordinate &&
      p.y.abs() <= ProjectLimits.maxCoordinate;
  bool rotation(double r) => r == 0 || r == 90 || r == 180 || r == 270;
  bool dimensions(DimensionsMm? d) =>
      d == null ||
      [d.width, d.height, d.depth].every((v) => v == null || positive(v));
  bool rect(RectUnits r) =>
      point(r.topLeft) && positive(r.width) && positive(r.height);

  List<Diagnostic> run() {
    id(project.id);
    try {
      validateProjectFrames(project);
    } on EcadException catch (error) {
      add(error.code, error.message);
    }
    if (!text(project.name, 200, required: true) ||
        !text(project.description, 8192))
      add(
        'invalid_metadata',
        'Project requires a bounded name and description.',
      );
    if (project.revision < 0 || project.revision > ProjectLimits.maxRevision)
      add('invalid_revision', 'Project revision is out of range.');
    if (project.pages.isEmpty || project.pages.length > ProjectLimits.maxPages)
      add(
        'invalid_page_count',
        'A project requires 1–${ProjectLimits.maxPages} sheets.',
      );
    final terminalCount = project.components.fold<int>(
      0,
      (n, c) => n + (c.electrical?.terminals.length ?? 0),
    );
    final portCount = project.pages.fold<int>(
      0,
      (n, s) =>
          n +
          s.devices.fold<int>(
            0,
            (n, d) =>
                n +
                switch (d.symbol) {
                  BuiltinSymbolSpec(:final bindings) => bindings.length,
                  PortBlockSpec(:final ports) => ports.length,
                  TerminalSymbolSpec(:final sides) => sides.length,
                },
          ),
    );
    final terminalRefs = project.components.fold<int>(
      0,
      (n, c) =>
          n +
          (c.electrical?.functions.fold<int>(
                0,
                (n, f) => n + f.terminalIds.length,
              ) ??
              0),
    );
    if (terminalRefs > ProjectLimits.maxTerminalReferences ||
        project.articles.length > ProjectLimits.maxArticles ||
        project.components.length > ProjectLimits.maxComponents ||
        project.mountingLayouts.length > ProjectLimits.maxPages ||
        project.continuationLinks.length > ProjectLimits.maxDevices ||
        terminalCount > ProjectLimits.maxTerminals ||
        portCount > ProjectLimits.maxPorts ||
        project.components.any(
          (c) =>
              (c.electrical?.terminals.length ?? 0) > 256 ||
              (c.electrical?.functions.length ?? 0) > 64,
        ) ||
        project.pages.any(
          (s) => s.devices.any(
            (d) => switch (d.symbol) {
              BuiltinSymbolSpec(:final bindings) => bindings.length > 256,
              PortBlockSpec(:final ports) => ports.length > 256,
              TerminalSymbolSpec() => false,
            },
          ),
        ) ||
        project.mountingLayouts.fold<int>(
              0,
              (n, l) => n + l.placements.length,
            ) >
            ProjectLimits.maxDevices ||
        project.pages.fold<int>(0, (n, s) => n + s.corners.length) >
            ProjectLimits.maxDevices ||
        project.pages.fold<int>(0, (n, s) => n + s.continuations.length) >
            ProjectLimits.maxDevices ||
        project.pages.fold<int>(0, (n, s) => n + s.devices.length) >
            ProjectLimits.maxDevices ||
        project.pages.fold<int>(0, (n, s) => n + s.wires.length) >
            ProjectLimits.maxWires ||
        project.pages.fold<int>(0, (n, s) => n + s.graphics.length) >
            ProjectLimits.maxGraphics) {
      add('limit_exceeded', 'Project exceeds domain collection limits.');
      return List.unmodifiable(diagnostics);
    }
    for (final article in project.articles) {
      validateArticle(article);
    }
    final designations = <String>{};
    final componentKeys = <String>{};
    for (final strip in project.terminalStrips) {
      id(strip.id);
      if (!validStructure(strip.reference.context) ||
          !validReferenceSegment(strip.reference.localDesignation)) {
        add('invalid_structure', 'Terminal strip reference is invalid.');
      }
      if (!designations.add(referenceKey(strip.reference.full))) {
        add('duplicate_designation', 'Terminal strip designation is repeated.');
      }
    }
    for (final component in project.components) {
      validateComponent(component);
      final designation = referenceKey(resolver.fullDesignation(component));
      if (designation.isNotEmpty &&
          (!designations.add(designation) ||
              !componentKeys.add(resolver.componentDesignationKey(component))))
        add(
          'duplicate_designation',
          'Component designation "${resolver.fullDesignation(component)}" is repeated.',
          componentId: component.id,
        );
    }
    final visited = <String>{};
    for (final component in project.components) {
      final path = <String>{};
      Component? current = component;
      while (current != null && !visited.contains(current.id)) {
        if (!path.add(current.id)) {
          add(
            'procurement_cycle',
            'Included supply references form a cycle.',
            componentId: component.id,
          );
          break;
        }
        current =
            resolver.components[current.procurement.includedInComponentId];
      }
      visited.addAll(path);
    }
    final linkLabels = <String>{};
    for (final link in project.continuationLinks) {
      id(link.id);
      if (!text(link.label, 200, required: true))
        add('invalid_metadata', 'Continuation requires a bounded label.');
      if (!linkLabels.add(link.label.trim().toLowerCase()))
        add(
          'duplicate_link_label',
          'Continuation label "${link.label}" is repeated.',
        );
    }
    validateMounting();
    final numbers = <String>{};
    final pageLabels = <String>{};
    var segments = 0;
    var imageChars = 0;
    for (final sheet in project.pages) {
      validateSheet(sheet);
      final number = pageDesignationKey(sheet);
      if (!numbers.add(number) ||
          !pageLabels.add(referenceKey(fullPageDesignation(sheet))))
        add(
          'duplicate_sheet_number',
          'Sheet number "${fullPageDesignation(sheet)}" is repeated.',
          sheetId: sheet.id,
        );
      for (final graphic in sheet.graphics) {
        id(graphic.id);
        segments += graphic.path.length;
        imageChars += graphic.imageData.length;
        if (segments > ProjectLimits.maxTotalPathSegments ||
            imageChars > ProjectLimits.maxTotalImageBase64Chars) {
          add('limit_exceeded', 'Project exceeds path or image limits.');
          return List.unmodifiable(diagnostics);
        }
        try {
          requireValidDrawingElement(graphic);
        } on EcadException catch (e) {
          add(e.code, e.message, sheetId: sheet.id, graphicId: graphic.id);
        }
      }
    }
    for (final report in project.pages.where((s) => s.report != null)) {
      final prefix = '${report.number.trim().toLowerCase()}.';
      for (final sheet in project.pages) {
        final number = sheet.number.trim().toLowerCase();
        if (sheet.id != report.id &&
            sheet.structure.key == report.structure.key &&
            referenceKey(sheet.documentCode) ==
                referenceKey(report.documentCode) &&
            number.startsWith(prefix) &&
            RegExp(r'^[0-9]+$').hasMatch(number.substring(prefix.length)) &&
            (int.tryParse(number.substring(prefix.length)) ?? 0) >= 2)
          add(
            'reserved_sheet_number',
            'Sheet number "${fullPageDesignation(sheet)}" is reserved for report continuation pages.',
            sheetId: sheet.id,
          );
      }
    }
    if (!diagnostics.any((d) => d.severity == DiagnosticSeverity.error))
      connectivityWarnings();
    return List.unmodifiable(diagnostics);
  }

  void validateArticle(Article a) {
    id(a.id);
    if (!text(a.name, 200, required: true) ||
        !text(a.manufacturer ?? '', 200) ||
        !text(a.partNumber ?? '', 200) ||
        !text(a.specification, 8192) ||
        !text(a.note, 8192))
      add(
        'invalid_metadata',
        'Article text exceeds format limits.',
        articleId: a.id,
      );
    if (!dimensions(a.dimensionsMm))
      add(
        'invalid_dimensions',
        'Article dimensions must be positive finite mm.',
        articleId: a.id,
      );
    if (a.sourceUrl != null) {
      final uri = Uri.tryParse(a.sourceUrl!);
      if (!text(a.sourceUrl!, 2048) ||
          uri == null ||
          !['https', 'http'].contains(uri.scheme) ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty)
        add(
          'invalid_source_url',
          'Article source must be an HTTP(S) URL without credentials.',
          articleId: a.id,
        );
    }
    if ((a.manufacturer ?? '').trim().isEmpty ||
        (a.partNumber ?? '').trim().isEmpty)
      add(
        'incomplete_article',
        'Article "${a.name}" lacks manufacturer or part number.',
        articleId: a.id,
        warning: true,
      );
  }

  void validateComponent(Component c) {
    id(c.id);
    final q = c.quantity.baseUnits;
    if (q != null && (q <= 0 || q > Quantity.maxBaseUnits))
      add(
        'invalid_quantity',
        'Component quantity must be positive or unspecified.',
        componentId: c.id,
      );
    if (c.kind == ComponentKind.physical &&
        (q != 1 || c.quantity.unit != QuantityUnit.piece))
      add(
        'physical_quantity',
        'A physical component is exactly one piece.',
        componentId: c.id,
      );
    if (!text(
          c.reference?.localDesignation ??
              c.terminal?.number ??
              c.designation ??
              '',
          64,
          required: c.kind == ComponentKind.physical,
        ) ||
        !text(c.description, 8192) ||
        !text(c.note, 8192) ||
        !text(c.location, 200))
      add(
        'invalid_metadata',
        'Component text is invalid or its designation is missing.',
        componentId: c.id,
      );
    if (c.reference case final ref?) {
      if (!validStructure(ref.context) ||
          !validReferenceSegment(ref.localDesignation)) {
        add(
          'invalid_structure',
          'Component reference contains an invalid segment.',
          componentId: c.id,
        );
      }
    }
    if (c.terminal case final terminal?) {
      if (c.reference != null ||
          c.kind != ComponentKind.physical ||
          c.electrical?.terminals.length != 1 ||
          c.electrical?.functions.length != 1 ||
          c.electrical?.functions.first.terminalIds.length != 1 ||
          project.terminalStripById(terminal.stripId) == null ||
          !validReferenceSegment(terminal.number) ||
          terminal.connectionPoints.keys
              .toSet()
              .difference(PortSide.values.map((s) => s.name).toSet())
              .isNotEmpty ||
          terminal.connectionPoints.values.any(
            (v) => !validReferenceSegment(v),
          ) ||
          terminal.connectionPoints.values.map(referenceKey).toSet().length !=
              terminal.connectionPoints.length) {
        add(
          'invalid_terminal',
          'A single-level through terminal requires one conductive node, one function, a known strip, a number and distinct connection point labels.',
          componentId: c.id,
        );
      }
    }
    final article = resolver.articles[c.articleId];
    if (c.articleId != null && article == null)
      add(
        'missing_article',
        'Component references an unknown article.',
        componentId: c.id,
      );
    if (article != null && article.unit != c.quantity.unit)
      add(
        'unit_mismatch',
        'Component and article units differ.',
        componentId: c.id,
      );
    if (c.articleId == null)
      add(
        'unassigned_article',
        'Component has no article.',
        warning: true,
        componentId: c.id,
      );
    if (q == null)
      add(
        'unknown_quantity',
        'Material quantity is unspecified.',
        warning: true,
        componentId: c.id,
      );
    final parentId = c.procurement.includedInComponentId;
    if (c.procurement.source == ProcurementSource.included) {
      if (parentId == null ||
          parentId == c.id ||
          !resolver.components.containsKey(parentId))
        add(
          'invalid_procurement',
          'Included supply requires another existing component.',
          componentId: c.id,
        );
    } else if (parentId != null) {
      add(
        'invalid_procurement',
        'Only included supply may reference another component.',
        componentId: c.id,
      );
    }
    if (!dimensions(c.mountingSizeOverrideMm) ||
        (c.kind == ComponentKind.material && c.mountingSizeOverrideMm != null))
      add(
        'invalid_dimensions',
        'Mounting dimensions belong to physical components and must be positive mm.',
        componentId: c.id,
      );
    final electrical = c.electrical;
    if (electrical == null) return;
    if (c.kind != ComponentKind.physical || c.usage != ComponentUsage.installed)
      add(
        'invalid_electrical_model',
        'Only installed physical components may have electrical functions.',
        componentId: c.id,
      );
    final terminals = electrical.terminals.map((t) => t.id).toSet();
    final names = <String>{};
    for (final terminal in electrical.terminals) {
      id(terminal.id);
      if (!text(terminal.designation, 64, required: true) ||
          !text(terminal.signal, 200))
        add(
          'invalid_metadata',
          'Terminal requires a bounded designation and signal.',
          componentId: c.id,
        );
      if (!names.add(terminal.designation.trim().toLowerCase()))
        add(
          'duplicate_terminal_designation',
          'Terminal designations must be unique within a component.',
          componentId: c.id,
        );
    }
    for (final function in electrical.functions) {
      id(function.id);
      if (!text(function.name, 200, required: true))
        add(
          'invalid_metadata',
          'Function requires a bounded name.',
          componentId: c.id,
        );
      if (function.terminalIds.length > 256 ||
          function.terminalIds.toSet().length != function.terminalIds.length ||
          function.terminalIds.any((id) => !terminals.contains(id)))
        add(
          'invalid_function_terminals',
          'Function terminals must be distinct references within their component.',
          componentId: c.id,
        );
    }
  }

  void validateDevice(Sheet sheet, Device d) {
    id(d.id);
    if (d.isMainFunction &&
        resolver.mainOccurrence(d.componentId)?.device.id != d.id) {
      add(
        'duplicate_main_function',
        'A component can have only one main function.',
        sheetId: sheet.id,
        deviceId: d.id,
        componentId: d.componentId,
      );
    }
    if (!point(d.position) || !rotation(d.rotation))
      add(
        'invalid_geometry',
        'Occurrence requires a finite position and a 0/90/180/270 rotation.',
        sheetId: sheet.id,
        deviceId: d.id,
      );
    final component = resolver.components[d.componentId];
    final function = component?.electrical?.functionById(d.functionId);
    if (component == null)
      add(
        'missing_component',
        'Occurrence references an unknown component.',
        sheetId: sheet.id,
        deviceId: d.id,
      );
    if (component != null &&
        (component.kind != ComponentKind.physical ||
            component.usage != ComponentUsage.installed))
      add(
        'invalid_occurrence',
        'Only installed physical components may appear in a schematic.',
        deviceId: d.id,
      );
    if (function == null)
      add(
        'missing_function',
        'Occurrence references an unknown function in its component.',
        deviceId: d.id,
      );
    final bindings = <String, String>{};
    switch (d.symbol) {
      case TerminalSymbolSpec(:final sides, :final terminalId):
        bindings.addAll({for (final side in sides) side.name: terminalId});
        if (component?.terminal == null ||
            sides.any(
              (s) => !component!.terminal!.connectionPoints.containsKey(s.name),
            )) {
          add(
            'invalid_terminal',
            'Terminal symbol requires a physical terminal and its connection points.',
            deviceId: d.id,
          );
        }
      case BuiltinSymbolSpec(:final kind, bindings: final map):
        if (kind == DeviceKind.earth)
          add(
            'logical_symbol',
            'Use a continuation marker for logical earth.',
            deviceId: d.id,
          );
        final expected = definitionFor(kind).ports.map((p) => p.id).toSet();
        if (map.length != expected.length || !expected.containsAll(map.keys))
          add(
            'invalid_port_binding',
            'Every catalogue port requires exactly one binding.',
            deviceId: d.id,
          );
        bindings.addAll(map);
      case PortBlockSpec(:final width, :final height, :final ports):
        if (!positive(width) || !positive(height))
          add(
            'invalid_geometry',
            'Block dimensions must be positive.',
            deviceId: d.id,
          );
        final positions = <(PortSide, double)>{};
        for (final p in ports) {
          if (!identifier.hasMatch(p.id) || bindings.containsKey(p.id))
            add(
              'invalid_port',
              'Block port IDs must be distinct valid local identifiers.',
              deviceId: d.id,
            );
          if (!p.fraction.isFinite ||
              p.fraction <= 0 ||
              p.fraction >= 1 ||
              !positions.add((p.side, p.fraction)))
            add(
              'invalid_port_geometry',
              'Block ports require distinct positions strictly inside an edge.',
              deviceId: d.id,
            );
          bindings[p.id] = p.terminalId;
        }
    }
    if (function != null &&
        bindings.values.any((t) => !function.terminalIds.contains(t)))
      add(
        'invalid_port_binding',
        'Ports must reference terminals of the selected function.',
        deviceId: d.id,
      );
  }

  void validateSheet(Sheet s) {
    id(s.id);
    if (!validStructure(s.structure) ||
        (s.documentCode.isNotEmpty && !validReferenceSegment(s.documentCode))) {
      add(
        'invalid_structure',
        'Sheet structure or document code is invalid.',
        sheetId: s.id,
      );
    }
    if (!positive(s.width) ||
        !positive(s.height) ||
        !positive(s.paperSizeMm.width) ||
        !positive(s.paperSizeMm.height))
      add(
        'invalid_geometry',
        'Sheet and paper sizes must be positive.',
        sheetId: s.id,
      );
    if (!text(s.name, 200, required: true) ||
        !text(s.number, 32, required: true) ||
        (s.sourcePage != null &&
            (s.sourcePage! < 1 || s.sourcePage! > ProjectLimits.maxSourcePage)))
      add(
        'invalid_metadata',
        'Sheet metadata exceeds format limits.',
        sheetId: s.id,
      );
    final electrical =
        s.type == SheetType.multiLine || s.type == SheetType.singleLine;
    if ((!electrical &&
            (s.corners.isNotEmpty ||
                s.devices.isNotEmpty ||
                s.wires.isNotEmpty ||
                s.continuations.isNotEmpty)) ||
        (s.mountingView != null && s.type != SheetType.cabinetLayout) ||
        (s.report != null && s.type != SheetType.billOfMaterials) ||
        (s.type == SheetType.billOfMaterials &&
            (s.report == null || s.graphics.isNotEmpty)))
      add(
        'incompatible_sheet_content',
        'Sheet type is incompatible with its content.',
        sheetId: s.id,
      );
    if (s.report case final report?) {
      if (!text(report.title, 200) || !text(report.note, 8192))
        add(
          'invalid_metadata',
          'Report text exceeds format limits.',
          sheetId: s.id,
        );
    }
    if (s.mountingView case final view?) {
      if (!resolver.layouts.containsKey(view.layoutId))
        add(
          'missing_layout',
          'View references an unknown mounting layout.',
          sheetId: s.id,
        );
      if (!point(view.originMm) ||
          !rect(view.viewport) ||
          !positive(view.scaleDenominator))
        add(
          'invalid_geometry',
          'Mounting view has invalid origin, viewport or scale.',
          sheetId: s.id,
        );
      if (view.viewport.x < 0 ||
          view.viewport.y < 0 ||
          view.viewport.x + view.viewport.width > s.width ||
          view.viewport.y + view.viewport.height > s.height)
        add(
          'viewport_outside_sheet',
          'Mounting viewport exceeds the sheet.',
          warning: true,
          sheetId: s.id,
        );
    }
    for (final d in s.devices) {
      validateDevice(s, d);
    }
    for (final corner in s.corners) {
      id(corner.id);
      if (!point(corner.position)) {
        add(
          'invalid_geometry',
          'Connection corner requires a finite position.',
          sheetId: s.id,
        );
      }
    }
    for (final m in s.continuations) {
      id(m.id);
      if (!point(m.position))
        add(
          'invalid_geometry',
          'Continuation position must be finite.',
          markerId: m.id,
        );
      if (project.continuationLinkById(m.linkId) == null)
        add(
          'missing_link',
          'Continuation references an unknown link.',
          markerId: m.id,
        );
    }
    final deviceMap = {for (final d in s.devices) d.id: d};
    final markerMap = {for (final m in s.continuations) m.id: m};
    final connections = <(WireEndpoint, WireEndpoint)>{};
    for (final w in s.wires) {
      id(w.id);
      if (w.waypoints.length > ProjectLimits.maxWaypoints ||
          w.waypoints.any((p) => !point(p)))
        add(
          'invalid_geometry',
          'Wire route exceeds format limits.',
          sheetId: s.id,
          wireId: w.id,
        );
      if (w.from == w.to)
        add(
          'same_endpoint',
          'Wire connects an endpoint to itself.',
          wireId: w.id,
        );
      for (final endpoint in [w.from, w.to]) {
        switch (endpoint) {
          case CornerRef(:final cornerId, :final portId):
            if (s.cornerById(cornerId)?.direction(portId) == null) {
              add(
                'invalid_corner_endpoint',
                'Wire references an unknown corner port on this sheet.',
                sheetId: s.id,
                wireId: w.id,
              );
            }
          case TerminalRef(:final deviceId, :final portId):
            final device = deviceMap[deviceId];
            if (device == null) {
              add(
                'missing_device',
                'Wire references an occurrence outside its sheet.',
                sheetId: s.id,
                wireId: w.id,
              );
            } else if (device.mode != OccurrenceMode.wiring) {
              add(
                'reference_endpoint',
                'Reference occurrences cannot accept wires.',
                wireId: w.id,
              );
            } else if (geometryFor(device).portById(portId) == null) {
              add(
                'invalid_port',
                'Wire ${w.id} references unknown port "$portId".',
                wireId: w.id,
              );
            }
          case ContinuationRef(:final markerId):
            if (!markerMap.containsKey(markerId))
              add(
                'missing_marker',
                'Wire references a continuation outside its sheet.',
                sheetId: s.id,
                wireId: w.id,
              );
        }
      }
      if (connections.contains((w.from, w.to)) ||
          connections.contains((w.to, w.from)))
        add(
          'duplicate_connection',
          'Two wires connect the same endpoints.',
          warning: true,
          wireId: w.id,
        );
      connections.add((w.from, w.to));
    }
  }

  void validateMounting() {
    // Far below fabrication precision; shared with the surface-edge check.
    const toleranceMm = 1e-8;
    final placed = <String>{};
    for (final layout in project.mountingLayouts) {
      id(layout.id);
      if (!text(layout.name, 200, required: true) ||
          !positive(layout.widthMm) ||
          !positive(layout.heightMm))
        add(
          'invalid_geometry',
          'Mounting surface requires a name and positive mm dimensions.',
          layoutId: layout.id,
        );
      if (layout.surfaceComponentId != null) {
        final surface = resolver.components[layout.surfaceComponentId];
        if (surface == null ||
            surface.kind != ComponentKind.physical ||
            surface.usage != ComponentUsage.installed)
          add(
            'invalid_surface_component',
            'Mounting surface must reference an installed physical component.',
            layoutId: layout.id,
          );
      }
      final bounds = <RectUnits>[];
      var overlaps = false;
      for (final placement in layout.placements) {
        id(placement.id);
        final component = resolver.components[placement.componentId];
        if (component == null ||
            component.kind != ComponentKind.physical ||
            component.usage != ComponentUsage.installed ||
            component.id == layout.surfaceComponentId)
          add(
            'invalid_placement',
            'Placement must reference an installed physical component distinct from the surface.',
            layoutId: layout.id,
            componentId: placement.componentId,
          );
        if (!placed.add(placement.componentId))
          add(
            'duplicate_placement',
            'A physical component may be placed only once; add another view instead.',
            componentId: placement.componentId,
          );
        if (!point(placement.centerMm) || !rotation(placement.rotation))
          add(
            'invalid_geometry',
            'Placement requires mm coordinates and a quarter-turn rotation.',
            layoutId: layout.id,
          );
        final box = resolver.mountingBounds(placement);
        if (box == null) {
          add(
            'missing_mounting_dimensions',
            'A placed component requires width and height in mm.',
            componentId: placement.componentId,
          );
          continue;
        }
        if (box.x < -toleranceMm ||
            box.y < -toleranceMm ||
            box.x + box.width > layout.widthMm + toleranceMm ||
            box.y + box.height > layout.heightMm + toleranceMm)
          add(
            'placement_outside_surface',
            'Component outline exceeds the mounting surface.',
            warning: true,
            componentId: placement.componentId,
            layoutId: layout.id,
          );
        if (!overlaps)
          overlaps = bounds.any(
            (b) =>
                box.x < b.x + b.width - toleranceMm &&
                b.x < box.x + box.width - toleranceMm &&
                box.y < b.y + b.height - toleranceMm &&
                b.y < box.y + box.height - toleranceMm,
          );
        bounds.add(box);
      }
      if (overlaps)
        add(
          'mounting_overlap',
          'Component outlines overlap on this surface.',
          warning: true,
          layoutId: layout.id,
        );
    }
  }

  void connectivityWarnings() {
    final index = ConnectivityIndex.build(project);
    final seen = <ElectricalNode>{};
    final markersByLink = <String, int>{};
    for (final sheet in project.pages) {
      for (final marker in sheet.continuations) {
        markersByLink.update(marker.linkId, (n) => n + 1, ifAbsent: () => 1);
      }
    }
    for (final sheet in project.pages) {
      for (final wire in sheet.wires.where((w) => w.waypoints.isNotEmpty)) {
        final path = resolver.wirePath(sheet, wire);
        final visitsAll = wire.waypoints.every((point) {
          for (var i = 1; i < path.length; i++) {
            if ((path[i - 1].distanceTo(point) +
                        point.distanceTo(path[i]) -
                        path[i - 1].distanceTo(path[i]))
                    .abs() <
                1e-6)
              return true;
          }
          return false;
        });
        if (!visitsAll) {
          add(
            'wire_waypoints_bypassed',
            'The current route bypasses retained manual anchors.',
            warning: true,
            sheetId: sheet.id,
            wireId: wire.id,
          );
        }
      }
      final used = {
        for (final wire in resolver.wires(sheet)) ...[wire.from, wire.to],
      };
      for (final device in sheet.devices.where(
        (d) => d.mode == OccurrenceMode.wiring,
      )) {
        final deviceNodes = <ElectricalNode>{};
        for (final port in resolver.ports(device)) {
          if (!deviceNodes.add(port.node)) continue;
          if (!seen.add(port.node)) {
            add(
              'repeated_wiring_terminal',
              'A terminal has multiple wiring occurrences.',
              warning: true,
              sheetId: sheet.id,
              deviceId: device.id,
            );
          } else if (!index.wiredNodes.contains(port.node)) {
            add(
              'unconnected_port',
              'Terminal ${port.label} is unconnected.',
              warning: true,
              sheetId: sheet.id,
              deviceId: device.id,
            );
          }
        }
      }
      for (final marker in sheet.continuations) {
        if (!used.contains(ContinuationRef(markerId: marker.id)))
          add(
            'unconnected_continuation',
            'Continuation has no local wire.',
            warning: true,
            sheetId: sheet.id,
            markerId: marker.id,
          );
        if (marker.glyph == ContinuationGlyph.arrow &&
            markersByLink[marker.linkId] == 1)
          add(
            'orphan_continuation',
            'Continuation arrow has no counterpart.',
            warning: true,
            sheetId: sheet.id,
            markerId: marker.id,
          );
      }
    }
  }
}

final _validProjects = Expando<bool>();

/// Throws only for structural errors; editorial/connectivity warnings remain
/// valid work-in-progress documents.
void requireValidProject(EcadProject project) {
  if (_validProjects[project] == true) return;
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
  _validProjects[project] = true;
}
