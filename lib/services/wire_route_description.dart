// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:ecad_core/ecad_core.dart';

import 'wire_hover_info.dart';

final _descriptions = Expando<_WireRouteDescriptions>(
  'wire route descriptions',
);

WireHoverInfo? resolveWireRouteHoverInfo({
  required ProjectResolver resolver,
  required Sheet sheet,
  required String wireId,
}) => (_descriptions[resolver] ??= _WireRouteDescriptions(resolver)).resolve(
  sheet.id,
  wireId,
);

class _WireRouteDescriptions {
  _WireRouteDescriptions(this.resolver);

  final ProjectResolver resolver;
  final _information = <(String, String), WireHoverInfo?>{};

  // Resolver identity ties the cache to one immutable scene, not project IDs.
  WireHoverInfo? resolve(String sheetId, String wireId) =>
      _information.putIfAbsent((sheetId, wireId), () {
        final sheet = resolver.sheets[sheetId];
        if (sheet == null) return null;
        return _describe(sheet, wireId);
      });

  late final _adjacency = _buildAdjacency();

  Map<ElectricalNode, List<({Sheet sheet, Wire wire, WireEndpoint endpoint})>>
  _buildAdjacency() {
    final adjacency =
        <
          ElectricalNode,
          List<({Sheet sheet, Wire wire, WireEndpoint endpoint})>
        >{};
    for (final page in resolver.project.pages) {
      for (final connection in resolver.wires(page)) {
        for (final (from, to) in [
          (connection.from, connection.to),
          (connection.to, connection.from),
        ]) {
          final node = resolver.nodeFor(page, from);
          if (node == null) continue;
          adjacency.putIfAbsent(node, () => []).add((
            sheet: page,
            wire: connection,
            endpoint: to,
          ));
        }
      }
    }
    return adjacency;
  }

  WireHoverInfo? _describe(Sheet sheet, String wireId) {
    final wire = resolver.wires(sheet).where((w) => w.id == wireId).firstOrNull;
    if (wire == null) return null;

    WireHoverEndpointInfo describe(WireEndpoint endpoint) {
      if (endpoint is TerminalRef) {
        return describeWireHoverEndpoint(
          resolver: resolver,
          sheet: sheet,
          endpoint: endpoint,
        );
      }
      final pending = [(sheet: sheet, endpoint: endpoint)];
      final visited = <ElectricalNode>{};
      final terminals = <WireHoverEndpointInfo>[];
      final pages = <String>{};
      while (pending.isNotEmpty) {
        final current = pending.removeLast();
        final node = resolver.nodeFor(current.sheet, current.endpoint);
        if (node == null || !visited.add(node)) continue;
        if (current.endpoint is TerminalRef) {
          terminals.add(
            describeWireHoverEndpoint(
              resolver: resolver,
              sheet: current.sheet,
              endpoint: current.endpoint,
            ),
          );
          pages.add(
            '${fullPageDesignation(current.sheet)} · ${current.sheet.name}',
          );
          continue;
        }
        for (final edge in _adjacency[node] ?? const []) {
          // Splitting at the hovered edge gives the two sides of a route, including branches.
          if (edge.sheet.id == sheet.id && edge.wire.id == wire.id) continue;
          pending.add((sheet: edge.sheet, endpoint: edge.endpoint));
        }
      }
      if (terminals.isEmpty) {
        if (endpoint is CornerRef) {
          return WireHoverEndpointInfo(
            label:
                'Spojovací roh ${sheet.cornerById(endpoint.cornerId)?.orientation.glyph ?? ''}',
            detail: 'Trasa bez připojeného přístrojového vývodu',
          );
        }
        return describeWireHoverEndpoint(
          resolver: resolver,
          sheet: sheet,
          endpoint: endpoint,
        );
      }
      terminals.sort((a, b) => a.label.compareTo(b.label));
      return WireHoverEndpointInfo(
        label:
            '${terminals.take(3).map((t) => t.label).join(', ')}${terminals.length > 3 ? ' (+${terminals.length - 3})' : ''}',
        detail: [
          if (terminals.length > 1) 'Větev · ${terminals.length} vývody',
          'List: ${pages.join(', ')}',
          if (terminals.length == 1 && terminals.single.detail != null)
            terminals.single.detail!,
        ].join(' · '),
      );
    }

    return resolveWireHoverInfo(
      resolver: resolver,
      sheetId: sheet.id,
      wireId: wire.id,
      wireResolver:
          ({required resolver, required sheet, required wireId}) => wire,
      endpointResolver:
          ({
            required resolver,
            required sheet,
            required wire,
            required endpoint,
          }) => describe(endpoint),
    );
  }
}
