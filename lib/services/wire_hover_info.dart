// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:ecad_core/ecad_core.dart';

class WireHoverEndpointInfo {
  const WireHoverEndpointInfo({required this.label, this.detail});

  final String label;
  final String? detail;
}

typedef WireHoverEndpointResolver =
    WireHoverEndpointInfo? Function({
      required ProjectResolver resolver,
      required Sheet sheet,
      required Wire wire,
      required WireEndpoint endpoint,
    });

typedef WireHoverWireResolver =
    Wire? Function({
      required ProjectResolver resolver,
      required Sheet sheet,
      required String wireId,
    });

class WireHoverInfo {
  const WireHoverInfo({
    required this.project,
    required this.sheetId,
    required this.wireId,
    required this.from,
    required this.to,
  });

  final EcadProject project;
  final String sheetId;
  final String wireId;
  final WireHoverEndpointInfo from;
  final WireHoverEndpointInfo to;

  String get label => '${from.label} → ${to.label}';

  String get detail => [
    if (_text(from.detail) case final text?) 'Odkud: $text',
    if (_text(to.detail) case final text?) 'Kam: $text',
  ].join('\n');

  String get tooltip => [label, if (detail.isNotEmpty) detail].join('\n');

  String get semanticsLabel => [
    'Spoj z ${from.label} do ${to.label}.',
    if (detail.isNotEmpty) detail,
  ].join('\n');
}

WireHoverInfo? resolveWireHoverInfo({
  required ProjectResolver resolver,
  required String sheetId,
  required String wireId,
  WireHoverEndpointResolver? endpointResolver,
  WireHoverWireResolver? wireResolver,
}) {
  final sheet = resolver.sheets[sheetId];
  if (sheet == null) return null;
  final wire =
      findById(sheet.wires, wireId, (wire) => wire.id) ??
      wireResolver?.call(resolver: resolver, sheet: sheet, wireId: wireId);
  if (wire == null || wire.id != wireId) return null;

  WireHoverEndpointInfo describe(WireEndpoint endpoint) =>
      endpointResolver?.call(
        resolver: resolver,
        sheet: sheet,
        wire: wire,
        endpoint: endpoint,
      ) ??
      describeWireHoverEndpoint(
        resolver: resolver,
        sheet: sheet,
        endpoint: endpoint,
      );

  return WireHoverInfo(
    project: resolver.project,
    sheetId: sheet.id,
    wireId: wire.id,
    from: describe(wire.from),
    to: describe(wire.to),
  );
}

WireHoverEndpointInfo describeWireHoverEndpoint({
  required ProjectResolver resolver,
  required Sheet sheet,
  required WireEndpoint endpoint,
}) {
  if (endpoint is TerminalRef) {
    final device = sheet.deviceById(endpoint.deviceId);
    if (device == null) {
      return const WireHoverEndpointInfo(label: 'Chybějící přístroj');
    }
    final component = resolver.components[device.componentId];
    if (component == null) {
      return const WireHoverEndpointInfo(label: 'Chybějící komponenta');
    }
    final designation = _text(resolver.fullDesignation(component));
    final port = resolver.port(device, endpoint.portId);
    final terminal =
        port == null
            ? 'vývod nenalezen'
            : _text(port.label) ?? 'vývod bez označení';
    final function = _text(
      component.electrical?.functionById(device.functionId)?.name,
    );
    final signal = _text(port?.signal);
    final description = _text(component.description);
    return WireHoverEndpointInfo(
      label: '${designation ?? 'Přístroj bez označení'}:$terminal',
      detail: _detail([
        if (designation == null && description != null) 'Popis: $description',
        if (function != null) 'Funkce: $function',
        if (signal != null) 'Signál: $signal',
        if (device.mode == OccurrenceMode.reference)
          'Referenční zobrazení, bez elektrického připojení',
      ]),
    );
  }

  if (endpoint is ContinuationRef) {
    final marker = sheet.continuationById(endpoint.markerId);
    if (marker == null) {
      return const WireHoverEndpointInfo(label: 'Chybějící pokračování');
    }
    final link = resolver.project.continuationLinkById(marker.linkId);
    final name = _text(link?.label);
    final targets =
        <String, Sheet>{
          for (final target in ContinuationIndex(
            resolver.project,
          ).targets(sheetId: sheet.id, markerId: marker.id))
            target.sheet.id: target.sheet,
        }.values.toList();
    return WireHoverEndpointInfo(
      label: name == null ? 'Pokračování bez názvu' : 'Pokračování $name',
      detail: _detail([
        if (link == null) 'Definice pokračování chybí',
        if (targets.isEmpty)
          'Cílový list není určen'
        else
          '${targets.length == 1 ? 'Cílový list' : 'Cílové listy'}: '
              '${targets.map(_sheetLabel).join(', ')}',
      ]),
    );
  }

  return const WireHoverEndpointInfo(
    label: 'Spojovací bod',
    detail: 'Navazující konec není určen',
  );
}

String _sheetLabel(Sheet sheet) {
  final number = _text(fullPageDesignation(sheet));
  final name = _text(sheet.name);
  return [number ?? 'bez čísla', name ?? 'bez názvu'].join(' — ');
}

String? _detail(List<String> parts) => parts.isEmpty ? null : parts.join(' · ');

String? _text(String? value) {
  final text = value?.replaceAll(RegExp(r'\s+'), ' ').trim();
  return text == null || text.isEmpty ? null : text;
}
