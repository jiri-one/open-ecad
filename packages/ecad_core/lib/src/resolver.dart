// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:math' as math;

import 'catalog.dart';
import 'autoconnect.dart';
import 'model.dart';
import 'routing.dart';

class ElectricalNode {
  const ElectricalNode.terminal(String componentId, String terminalId)
    : componentId = componentId,
      terminalId = terminalId,
      linkId = null,
      cornerId = null;
  const ElectricalNode.link(String linkId)
    : linkId = linkId,
      componentId = null,
      terminalId = null,
      cornerId = null;
  const ElectricalNode.corner(String cornerId)
    : cornerId = cornerId,
      componentId = null,
      terminalId = null,
      linkId = null;
  final String? cornerId;
  final String? componentId;
  final String? terminalId;
  final String? linkId;
  @override
  bool operator ==(Object other) =>
      other is ElectricalNode &&
      componentId == other.componentId &&
      terminalId == other.terminalId &&
      linkId == other.linkId &&
      cornerId == other.cornerId;
  @override
  int get hashCode => Object.hash(componentId, terminalId, linkId, cornerId);
}

class ResolvedPort {
  const ResolvedPort({
    required this.ref,
    required this.node,
    required this.label,
    required this.signal,
    required this.geometry,
    required this.connectable,
  });
  final TerminalRef ref;
  final ElectricalNode node;
  final String label;
  final String signal;
  final WireTerminal geometry;
  final bool connectable;
}

typedef DeviceOccurrence = ({Sheet sheet, Device device});

class ProjectResolver {
  ProjectResolver(this.project)
    : articles = Map.unmodifiable({for (final a in project.articles) a.id: a}),
      components = Map.unmodifiable({
        for (final c in project.components) c.id: c,
      }),
      layouts = Map.unmodifiable({
        for (final l in project.mountingLayouts) l.id: l,
      }),
      sheets = Map.unmodifiable({for (final s in project.pages) s.id: s});
  final EcadProject project;
  final Map<String, Article> articles;
  final Map<String, Component> components;
  final Map<String, MountingLayout> layouts;
  final Map<String, Sheet> sheets;

  StructureContext contextFor(Component component) =>
      component.terminal == null
          ? component.reference?.context ?? const StructureContext.empty()
          : project
                  .terminalStripById(component.terminal!.stripId)
                  ?.reference
                  .context ??
              const StructureContext.empty();

  String fullDesignation(Component component) {
    final terminal = component.terminal;
    if (terminal == null) return component.designation ?? '';
    final strip = project.terminalStripById(terminal.stripId);
    return '${strip?.reference.full ?? '?'}:${terminal.number}';
  }

  String relativeDesignation(Component component, StructureContext context) {
    final terminal = component.terminal;
    if (terminal == null)
      return component.reference?.relativeTo(context) ??
          component.designation ??
          '';
    final strip = project.terminalStripById(terminal.stripId);
    return '${strip?.reference.relativeTo(context) ?? '?'}:${terminal.number}';
  }

  String componentDesignationKey(Component component) =>
      component.terminal == null
          ? component.reference?.key ??
              referenceKey(component.designation ?? '')
          : '${project.terminalStripById(component.terminal!.stripId)?.reference.key}:${referenceKey(component.terminal!.number)}';

  String terminalStripLabel(Component component) =>
      project
          .terminalStripById(component.terminal?.stripId ?? '')
          ?.reference
          .full ??
      fullDesignation(component);

  DimensionsMm dimensionsFor(Component component) {
    final own = component.mountingSizeOverrideMm;
    final article = articles[component.articleId]?.dimensionsMm;
    return DimensionsMm(
      width: own?.width ?? article?.width,
      height: own?.height ?? article?.height,
      depth: own?.depth ?? article?.depth,
    );
  }

  ResolvedPort? port(Device device, String portId) {
    final terminalId = terminalIdFor(device, portId);
    final component = components[device.componentId];
    final terminal =
        terminalId == null
            ? null
            : component?.electrical?.terminalById(terminalId);
    final geometry = WireRouter.terminal(device, portId);
    if (terminal == null || geometry == null) return null;
    return ResolvedPort(
      ref: TerminalRef(deviceId: device.id, portId: portId),
      node: ElectricalNode.terminal(device.componentId, terminal.id),
      label:
          device.symbol is TerminalSymbolSpec
              ? component!.terminal?.connectionPoints[portId] ??
                  terminal.designation
              : terminal.designation,
      signal: terminal.signal,
      geometry: geometry,
      connectable: device.mode == OccurrenceMode.wiring,
    );
  }

  List<ResolvedPort> ports(Device device) => List.unmodifiable([
    for (final p in geometryFor(device).ports)
      if (port(device, p.id) case final resolved?) resolved,
  ]);

  ElectricalNode? nodeFor(Sheet sheet, WireEndpoint endpoint) {
    switch (endpoint) {
      case CornerRef(:final cornerId, :final portId):
        final corner = sheet.cornerById(cornerId);
        return corner?.direction(portId) == null
            ? null
            : ElectricalNode.corner(cornerId);
      case TerminalRef(:final deviceId, :final portId):
        final device = sheet.deviceById(deviceId);
        if (device == null || device.mode == OccurrenceMode.reference)
          return null;
        return port(device, portId)?.node;
      case ContinuationRef(:final markerId):
        final marker = sheet.continuationById(markerId);
        return marker == null ? null : ElectricalNode.link(marker.linkId);
    }
  }

  List<({Sheet sheet, ContinuationMarker marker})> continuationTargets(
    ContinuationMarker marker,
  ) => List.unmodifiable([
    for (final sheet in project.pages)
      for (final other in sheet.continuations)
        if (other.id != marker.id && other.linkId == marker.linkId)
          (sheet: sheet, marker: other),
  ]);

  List<Wire> wires(Sheet sheet) => AutoConnect.wires(sheet);

  late final Map<String, List<DeviceOccurrence>> _occurrences = () {
    final result = <String, List<DeviceOccurrence>>{};
    for (final sheet in project.pages) {
      for (final device in sheet.devices) {
        result.putIfAbsent(device.componentId, () => []).add((
          sheet: sheet,
          device: device,
        ));
      }
    }
    return result;
  }();

  late final Map<String, DeviceOccurrence> _mainOccurrences = {
    for (final entry in _occurrences.entries)
      entry.key:
          entry.value.where((o) => o.device.isMainFunction).firstOrNull ??
          entry.value
              .where((o) => o.device.mode == OccurrenceMode.wiring)
              .firstOrNull ??
          entry.value.first,
  };

  DeviceOccurrence? mainOccurrence(String componentId) =>
      _mainOccurrences[componentId];

  DeviceOccurrence? schematicOccurrence(
    String componentId, {
    String? terminalId,
  }) {
    if (!components.containsKey(componentId)) return null;
    final all = _occurrences[componentId] ?? const <DeviceOccurrence>[];
    bool eligible(DeviceOccurrence o) =>
        (o.sheet.type == SheetType.multiLine ||
            o.sheet.type == SheetType.singleLine) &&
        (terminalId == null ||
            ports(o.device).any((p) => p.node.terminalId == terminalId));
    final explicit = all.where((o) => o.device.isMainFunction).toList();
    if (explicit.isNotEmpty) {
      return explicit.length == 1 && eligible(explicit.single)
          ? explicit.single
          : null;
    }
    final candidates =
        all
            .where((o) => eligible(o) && o.device.mode == OccurrenceMode.wiring)
            .toList();
    return candidates.length == 1 ? candidates.single : null;
  }

  bool isMainFunction(Device device) =>
      mainOccurrence(device.componentId)?.device.id == device.id;

  List<DeviceOccurrence> otherOccurrences(Device device) {
    final mainId = mainOccurrence(device.componentId)?.device.id;
    final others = (_occurrences[device.componentId] ??
            const <DeviceOccurrence>[])
        .where((o) => o.device.id != device.id);
    return List.unmodifiable([
      ...others.where((o) => o.device.id == mainId),
      ...others.where((o) => o.device.id != mainId),
    ]);
  }

  String crossReferences(Device device) => otherOccurrences(device)
      .map(
        (o) =>
            '${fullPageDesignation(o.sheet)}${isMainFunction(o.device) ? ' (H)' : ''} · ${o.device.position.x}/${o.device.position.y}',
      )
      .join(', ');

  List<Vec2> wirePath(Sheet sheet, Wire wire) => WireRouter.path(
    wire,
    {for (final d in sheet.devices) d.id: d},
    {for (final m in sheet.continuations) m.id: m},
    {for (final c in sheet.corners) c.id: c},
  );

  RectUnits? mountingBounds(MountingPlacement placement) {
    final component = components[placement.componentId];
    if (component == null) return null;
    final size = dimensionsFor(component);
    if (size.width == null || size.height == null) return null;
    return rotatedBounds(
      placement.centerMm,
      size.width!,
      size.height!,
      placement.rotation,
    );
  }
}

RectUnits rotatedBounds(
  Vec2 center,
  double width,
  double height,
  double rotation,
) {
  final corners = [
    for (final x in [-width / 2, width / 2])
      for (final y in [-height / 2, height / 2])
        center + Vec2(x, y).rotated(rotation),
  ];
  final left = corners.map((p) => p.x).reduce(math.min);
  final top = corners.map((p) => p.y).reduce(math.min);
  return RectUnits(
    x: left,
    y: top,
    width: corners.map((p) => p.x).reduce(math.max) - left,
    height: corners.map((p) => p.y).reduce(math.max) - top,
  );
}

class SheetTransform {
  SheetTransform(Sheet sheet)
    : mmPerUnit = math.min(
        sheet.paperSizeMm.width / sheet.width,
        sheet.paperSizeMm.height / sheet.height,
      ),
      sheetSize = Vec2(sheet.width, sheet.height),
      paperSize = Vec2(sheet.paperSizeMm.width, sheet.paperSizeMm.height);
  final double mmPerUnit;
  final Vec2 sheetSize;
  final Vec2 paperSize;
  Vec2 get offsetMm => (paperSize - sheetSize * mmPerUnit) / 2;
  Vec2 toPaperMm(Vec2 point) => offsetMm + point * mmPerUnit;
  Vec2 fromPaperMm(Vec2 point) => (point - offsetMm) / mmPerUnit;
  Vec2 toPdfPoints(Vec2 point) => toPaperMm(point) * (72 / 25.4);
  RectUnits get paperBoundsUnits {
    final origin = fromPaperMm(Vec2.zero);
    return RectUnits(
      x: origin.x,
      y: origin.y,
      width: paperSize.x / mmPerUnit,
      height: paperSize.y / mmPerUnit,
    );
  }
}

class MountingTransform {
  MountingTransform(Sheet sheet, this.view) : paper = SheetTransform(sheet);
  final SheetTransform paper;
  final MountingView view;
  double get unitsPerMm => 1 / (paper.mmPerUnit * view.scaleDenominator);
  Vec2 toSheet(Vec2 pointMm) =>
      view.viewport.topLeft + (pointMm - view.originMm) * unitsPerMm;
  Vec2 toMountingMm(Vec2 point) =>
      view.originMm + (point - view.viewport.topLeft) / unitsPerMm;
}

class ConnectivityIndex {
  ConnectivityIndex._(
    this.resolver,
    Map<ElectricalNode, ElectricalNode> roots,
    Set<ElectricalNode> wired,
  ) : _roots = Map.unmodifiable(roots),
      wiredNodes = Set.unmodifiable(wired);
  final ProjectResolver resolver;
  final Map<ElectricalNode, ElectricalNode> _roots;
  final Set<ElectricalNode> wiredNodes;
  bool connected(ElectricalNode a, ElectricalNode b) =>
      _roots.containsKey(a) && _roots[a] == _roots[b];
  Set<ElectricalNode> net(ElectricalNode node) =>
      Set.unmodifiable(_roots.keys.where((other) => connected(node, other)));

  factory ConnectivityIndex.build(EcadProject project) {
    final resolver = ProjectResolver(project);
    final parent = <ElectricalNode, ElectricalNode>{};
    ElectricalNode root(ElectricalNode node) {
      parent.putIfAbsent(node, () => node);
      var current = node;
      while (parent[current] != current) {
        parent[current] = parent[parent[current]]!;
        current = parent[current]!;
      }
      return current;
    }

    final wired = <ElectricalNode>{};
    for (final sheet in project.pages) {
      for (final device in sheet.devices.where(
        (d) => d.mode == OccurrenceMode.wiring,
      )) {
        for (final port in resolver.ports(device)) {
          root(port.node);
        }
      }
      for (final marker in sheet.continuations) {
        root(ElectricalNode.link(marker.linkId));
      }
      for (final corner in sheet.corners) {
        root(ElectricalNode.corner(corner.id));
      }
      for (final wire in resolver.wires(sheet)) {
        final a = resolver.nodeFor(sheet, wire.from);
        final b = resolver.nodeFor(sheet, wire.to);
        if (a == null || b == null) continue;
        parent[root(a)] = root(b);
        wired.addAll([a, b]);
      }
    }
    return ConnectivityIndex._(resolver, {
      for (final node in parent.keys.toList()) node: root(node),
    }, wired);
  }
}
