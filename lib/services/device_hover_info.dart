// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:ecad_core/ecad_core.dart';

import 'canvas_hover_info.dart';

class DeviceHoverInfo implements CanvasHoverInfo {
  const DeviceHoverInfo({
    required this.project,
    required this.sheetId,
    required this.targetIdentity,
    required this.label,
    required this.detail,
  });

  @override
  final EcadProject project;
  @override
  final String sheetId;
  @override
  final Object targetIdentity;
  @override
  final String label;
  @override
  final String detail;

  @override
  String get tooltip => [label, if (detail.isNotEmpty) detail].join('\n');

  @override
  String get semanticsLabel => 'Přístroj $tooltip';
}

DeviceHoverInfo? resolveDeviceHoverInfo({
  required ProjectResolver resolver,
  required String sheetId,
  required String deviceId,
}) {
  final device = resolver.sheets[sheetId]?.deviceById(deviceId);
  if (device == null) return null;
  final component = resolver.components[device.componentId];
  if (component == null) return null;
  return _describe(
    resolver: resolver,
    sheetId: sheetId,
    identity: ('device', deviceId, component.id),
    component: component,
    symbol: switch (device.symbol) {
      BuiltinSymbolSpec(:final kind) => SymbolCatalog.definitionFor(kind).label,
      TerminalSymbolSpec() => 'Svorka',
      PortBlockSpec() => 'Blok s vývody',
    },
    functions: [
      if (component.electrical?.functionById(device.functionId) case final f?)
        f.name,
    ],
    reference: device.mode == OccurrenceMode.reference,
  );
}

DeviceHoverInfo? resolveMountingHoverInfo({
  required ProjectResolver resolver,
  required String sheetId,
  required String placementId,
}) {
  final view = resolver.sheets[sheetId]?.mountingView;
  if (view == null) return null;
  final placement = findById(
    resolver.layouts[view.layoutId]?.placements ?? <MountingPlacement>[],
    placementId,
    (placement) => placement.id,
  );
  final component = resolver.components[placement?.componentId];
  if (component == null) return null;
  return _describe(
    resolver: resolver,
    sheetId: sheetId,
    identity: ('placement', view.layoutId, placementId, component.id),
    component: component,
    functions: [for (final f in component.electrical?.functions ?? []) f.name],
  );
}

DeviceHoverInfo _describe({
  required ProjectResolver resolver,
  required String sheetId,
  required Object identity,
  required Component component,
  required List<String> functions,
  String? symbol,
  bool reference = false,
}) {
  final article = resolver.articles[component.articleId];
  final function = functions.map(_text).nonNulls.toSet().join(', ');
  final size = resolver.dimensionsFor(component);
  final dimensions = [
    if (_dimension(size.width) case final width?) 'š $width',
    if (_dimension(size.height) case final height?) 'v $height',
    if (_dimension(size.depth) case final depth?) 'h $depth',
  ];
  return DeviceHoverInfo(
    project: resolver.project,
    sheetId: sheetId,
    targetIdentity: identity,
    label:
        _text(resolver.fullDesignation(component)) ?? 'Přístroj bez označení',
    detail: [
      if (_text(component.description) case final text?) 'Popis: $text',
      if (symbol != null) 'Symbol: $symbol',
      if (function.isNotEmpty && function != symbol) 'Funkce: $function',
      if (_text(article?.name) case final text?) 'Artikl: $text',
      if (_text(article?.manufacturer) case final text?) 'Výrobce: $text',
      if (_text(article?.partNumber) case final text?) 'Model: $text',
      if (dimensions.isNotEmpty) 'Rozměry: ${dimensions.join(' × ')} mm',
      if (reference) 'Referenční zobrazení, bez elektrického připojení',
    ].join('\n'),
  );
}

String? _dimension(double? value) =>
    value != null && value.isFinite && value > 0
        ? value.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '')
        : null;

String? _text(String? value) {
  final text = value?.replaceAll(RegExp(r'\s+'), ' ').trim();
  return text == null || text.isEmpty ? null : text;
}
