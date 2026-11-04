// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:math' as math;

import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/painting.dart';

import 'report_layout.dart';

class PortAnnotation {
  const PortAnnotation(this.port, this.text, this.bounds);
  final ResolvedPort port;
  final String text;
  final Rect bounds;
}

Rect _textBounds(
  String text,
  double x,
  double y,
  double size, {
  bool bold = false,
  bool baseline = false,
}) {
  final painter = reportTextPainter(text, size, bold: bold);
  final top =
      baseline
          ? y - painter.computeDistanceToActualBaseline(TextBaseline.alphabetic)
          : y;
  final bounds = Rect.fromLTWH(x, top, painter.width, painter.height);
  painter.dispose();
  return bounds;
}

Iterable<Rect> deviceAnnotationBounds(
  ProjectResolver resolver,
  Device device,
) sync* {
  final component = resolver.components[device.componentId]!;
  final ports = layoutPortAnnotations(resolver, device);
  yield* ports.map((p) => p.bounds);
  yield* layoutDeviceCrossReferences(resolver, device).map((r) => r.bounds);
  if (device.symbol case TerminalSymbolSpec(:final sides)) {
    final labels =
        TerminalSymbolGeometry(
          sides: sides,
          center: device.position,
          quarterTurns: device.rotation ~/ 90,
        ).labelLayout();
    final designation = resolver.terminalStripLabel(component);
    final number = component.terminal!.number;
    yield _textBounds(
      designation,
      labels.designationOrigin.x,
      labels.designationOrigin.y,
      11,
      bold: true,
    ).inflate(2);
    yield _textBounds(
      number,
      labels.numberOrigin.x,
      labels.numberOrigin.y,
      11,
    ).inflate(2);
    return;
  }
  final geometry = geometryFor(device);
  final bounds = rotatedBounds(
    device.position,
    geometry.width,
    geometry.height,
    device.rotation,
  );
  final right = bounds.x + bounds.width;
  final designation = resolver.fullDesignation(component);
  final subtitle =
      component.description.isNotEmpty
          ? component.description
          : device.kind == null
          ? 'Obecný blok'
          : device.kind == DeviceKind.coil
          ? 'Cívka relé'
          : schematicKindName(device.kind!);
  yield _textBounds(
    designation,
    right + 14,
    device.position.y - 17,
    11,
    bold: true,
  ).inflate(2);
  yield _textBounds(
    subtitle,
    right + 14,
    device.position.y + 1,
    8.5,
  ).inflate(2);

  // Exports include article/function descriptions and wrapped references.
  final x = ports.fold<double>(
    right + 16,
    (x, p) => math.max(x, p.bounds.right + 12),
  );
  yield _textBounds(
    designation,
    x,
    device.position.y - 5,
    12,
    bold: true,
    baseline: true,
  );
  final article = resolver.articles[component.articleId];
  final function = component.electrical?.functionById(device.functionId);
  final exportSubtitle = [
    if (device.mode == OccurrenceMode.reference) 'Reference',
    if (article?.specification.isNotEmpty ?? false)
      article!.specification
    else if (function != null)
      function.name
    else if (device.kind != null)
      schematicKindName(device.kind!),
  ].join(' · ');
  final lines = [
    ...wrapSchematicText(exportSubtitle, 42),
    ...wrapSchematicText(component.description, 42),
  ];
  final references = resolver.otherOccurrences(device);
  if (references.isNotEmpty) {
    lines.addAll(
      wrapSchematicText(
        'viz ${references.map((target) => '${fullPageDesignation(target.sheet)}${resolver.isMainFunction(target.device) ? ' (H)' : ''} · ${target.device.position.x}/${target.device.position.y}').join(', ')}'
            .replaceAll(RegExp(r'\s+'), ' '),
        42,
      ),
    );
  }
  for (final (i, line) in lines.indexed) {
    yield _textBounds(
      line,
      x,
      device.position.y + 11 + i * 13,
      9,
      baseline: true,
    );
  }
}

Iterable<Rect> continuationAnnotationBounds(
  EcadProject project,
  Sheet sheet,
  ContinuationMarker marker,
  ContinuationIndex index,
) sync* {
  final pages =
      index
          .targets(sheetId: sheet.id, markerId: marker.id)
          .map((t) => fullPageDesignation(t.sheet))
          .toSet();
  final label = project.continuationLinkById(marker.linkId)!.label;
  yield _textBounds(
    '$label → ${pages.isEmpty ? 'bez cíle' : pages.join(', ')}',
    marker.position.x + 14,
    marker.position.y - 10,
    10,
  ).inflate(2);
  final sorted = pages.toList()..sort(naturalCompare);
  final lines = wrapSchematicText(
    '$label -> ${sorted.isEmpty ? 'bez protějšku' : sorted.join(', ')}'
        .replaceAll(RegExp(r'\s+'), ' '),
    48,
  );
  for (final (i, line) in lines.indexed) {
    yield _textBounds(
      line,
      marker.position.x + 8,
      marker.position.y - 12 + (i + 1 - lines.length) * 13,
      9,
      baseline: true,
    );
  }
}

class DeviceCrossReference {
  const DeviceCrossReference(
    this.sourceId,
    this.target,
    this.text,
    this.bounds,
    this.baseline,
  );
  final String sourceId;
  final DeviceOccurrence target;
  final String text;
  final Rect bounds;
  final double baseline;
}

class ContinuationCrossReference {
  const ContinuationCrossReference(this.markerId, this.text, this.bounds);
  final String markerId, text;
  final Rect bounds;
}

ContinuationCrossReference? layoutContinuationCrossReference(
  EcadProject project,
  Sheet sheet,
  ContinuationMarker marker, {
  ContinuationIndex? index,
}) {
  final targets = (index ?? ContinuationIndex(project)).targets(
    sheetId: sheet.id,
    markerId: marker.id,
  );
  if (targets.isEmpty) return null;
  final text =
      '${project.continuationLinkById(marker.linkId)!.label} → ${targets.map((t) => fullPageDesignation(t.sheet)).toSet().join(', ')}';
  final painter = reportTextPainter(text, 10);
  final bounds = Rect.fromLTWH(
    marker.position.x + 14,
    marker.position.y - 10,
    painter.width,
    painter.height,
  );
  painter.dispose();
  return ContinuationCrossReference(marker.id, text, bounds);
}

List<DeviceCrossReference> layoutDeviceCrossReferences(
  ProjectResolver resolver,
  Device device,
) {
  final targets = resolver.otherOccurrences(device);
  if (targets.isEmpty) return const [];
  final geometry = geometryFor(device);
  final bounds = rotatedBounds(
    device.position,
    geometry.width,
    geometry.height,
    device.rotation,
  );
  final terminal =
      device.symbol is TerminalSymbolSpec
          ? TerminalSymbolGeometry(
            sides: (device.symbol as TerminalSymbolSpec).sides,
            center: device.position,
            quarterTurns: device.rotation ~/ 90,
          ).labelLayout()
          : null;
  var x = terminal?.designationOrigin.x ?? bounds.x + bounds.width + 18;
  if (terminal == null) {
    for (final port in layoutPortAnnotations(resolver, device)) {
      if (port.bounds.right + 12 > x) x = port.bounds.right + 12;
    }
  }
  var y = (terminal?.numberOrigin.y ?? device.position.y + 1) + 14;
  final result = <DeviceCrossReference>[];
  for (final target in targets) {
    final point = target.device.position;
    final text =
        '${fullPageDesignation(target.sheet)}${resolver.isMainFunction(target.device) ? ' (H)' : ''} · ${point.x.toStringAsFixed(1)}/${point.y.toStringAsFixed(1)}';
    final painter = reportTextPainter(text, 8.5);
    final rect = Rect.fromLTWH(x, y, painter.width, painter.height);
    final baseline = y + painter.computeLineMetrics().first.baseline;
    painter.dispose();
    y = rect.bottom + 3;
    result.add(DeviceCrossReference(device.id, target, text, rect, baseline));
  }
  return List.unmodifiable(result);
}

List<PortAnnotation> layoutPortAnnotations(
  ProjectResolver resolver,
  Device device,
) {
  if (device.symbol is TerminalSymbolSpec) return const [];
  final result = <PortAnnotation>[];
  for (final port in resolver.ports(device)) {
    final label = [
      port.label,
      port.signal,
    ].where((s) => s.isNotEmpty).join(' · ');
    final painter = reportTextPainter(label, 9)..layout(maxWidth: 180);
    final lines = [
      for (final line in painter.computeLineMetrics())
        painter.getLineBoundary(
          painter.getPositionForOffset(
            Offset(0, line.baseline - line.ascent / 2),
          ),
        ),
    ];
    final wrapped = lines
        .map((line) => label.substring(line.start, line.end).trim())
        .join('\n');
    final width = painter.width + 4;
    final height = painter.height + 2;
    painter.dispose();
    final p = port.geometry.point;
    final n = port.geometry.direction;
    var rect = Rect.fromLTWH(
      n.x < 0
          ? p.x - width - 6
          : n.x > 0
          ? p.x + 6
          : p.x + 4,
      n.y < 0
          ? p.y - height - 4
          : n.y > 0
          ? p.y + 4
          : p.y - height - 3,
      width,
      height,
    );
    // Stagger dense adjacent pins without rotating their readable labels.
    while (result.any((r) => r.bounds.inflate(2).overlaps(rect))) {
      rect = rect.shift(Offset(0, n.y > 0 ? height + 3 : -height - 3));
    }
    result.add(PortAnnotation(port, wrapped, rect));
  }
  return List.unmodifiable(result);
}

String schematicKindName(DeviceKind kind) => switch (kind) {
  DeviceKind.supply => 'Napájení',
  DeviceKind.breaker => 'Jistič',
  DeviceKind.threePoleBreaker => 'Třípólový jistič',
  DeviceKind.fuse => 'Pojistka',
  DeviceKind.disconnector => 'Odpojovač',
  DeviceKind.threePoleDisconnector => 'Třípólový odpojovač',
  DeviceKind.contactor => 'Stykač',
  DeviceKind.motor => 'Motor',
  DeviceKind.transformer => 'Transformátor',
  DeviceKind.currentTransformer => 'Transformátor proudu',
  DeviceKind.terminal => 'Svorka',
  DeviceKind.earth => 'Ochranné uzemnění',
  DeviceKind.contactNo => 'Spínací kontakt',
  DeviceKind.contactNc => 'Rozpínací kontakt',
  DeviceKind.pushbuttonNo => 'Spínací tlačítko',
  DeviceKind.coil => 'Cívka',
  DeviceKind.lamp => 'Kontrolka',
  DeviceKind.ammeter => 'Ampérmetr',
  DeviceKind.voltmeter => 'Voltmetr',
};

List<String> wrapSchematicText(String text, int width) {
  if (text.isEmpty) return const [];
  final lines = <String>[];
  var line = '';
  for (final word in text.split(RegExp(r'\s+'))) {
    if (line.length + word.length + 1 > width && line.isNotEmpty) {
      lines.add(line);
      line = '';
    }
    if (word.length > width) {
      if (line.isNotEmpty) {
        lines.add(line);
        line = '';
      }
      for (var start = 0; start < word.length; start += width) {
        final end = math.min(start + width, word.length);
        lines.add(word.substring(start, end));
      }
    } else {
      line = line.isEmpty ? word : '$line $word';
    }
  }
  if (line.isNotEmpty) lines.add(line);
  return lines;
}
