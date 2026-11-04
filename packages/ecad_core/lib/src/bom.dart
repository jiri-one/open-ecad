// SPDX-License-Identifier: GPL-3.0-or-later
import 'model.dart';
import 'resolver.dart';
import 'validation.dart';

class QuantityTotal {
  QuantityTotal({
    required this.knownBaseUnits,
    Set<String> unknownComponentIds = const {},
  }) : unknownComponentIds = Set.unmodifiable(unknownComponentIds);
  final int knownBaseUnits;
  final Set<String> unknownComponentIds;
  bool get isKnown => unknownComponentIds.isEmpty;
  String display(QuantityUnit unit) {
    final known = _quantityCell(Quantity.formatBaseUnits(unit, knownBaseUnits));
    return isKnown
        ? known
        : knownBaseUnits == 0
        ? 'neurčeno'
        : '$known + neurčeno';
  }
}

String _quantityCell(String? amount) =>
    amount?.replaceAll('.', ',') ?? 'neurčeno';

class BomArticleRow {
  BomArticleRow({
    required this.rowKey,
    required this.article,
    required this.unit,
    required List<String> componentIds,
    required List<String> designations,
    required this.installed,
    required this.spare,
    required this.available,
    required this.included,
    required this.toPurchase,
    required this.requiredTotal,
  }) : componentIds = List.unmodifiable(componentIds),
       designations = List.unmodifiable(designations);
  final String rowKey;
  final Article? article;
  String? get articleId => article?.id;
  final QuantityUnit unit;
  final List<String> componentIds;
  final List<String> designations;
  final QuantityTotal installed;
  final QuantityTotal spare;
  final QuantityTotal available;
  final QuantityTotal included;
  final QuantityTotal toPurchase;
  final QuantityTotal requiredTotal;
  bool get articleComplete =>
      article != null &&
      (article!.manufacturer ?? '').trim().isNotEmpty &&
      (article!.partNumber ?? '').trim().isNotEmpty;
}

class ComponentRow {
  ComponentRow({
    required this.component,
    required this.article,
    required List<({String sheetId, String deviceId})> occurrences,
    required List<String> mountingSheetIds,
    required this.layoutId,
    required this.placementId,
    required this.includedInDesignation,
  }) : occurrences = List.unmodifiable(occurrences),
       mountingSheetIds = List.unmodifiable(mountingSheetIds);
  final Component component;
  final Article? article;
  final List<({String sheetId, String deviceId})> occurrences;
  final List<String> mountingSheetIds;
  final String? layoutId;
  final String? placementId;
  final String? includedInDesignation;
  bool get hasRepresentation =>
      occurrences.isNotEmpty || mountingSheetIds.isNotEmpty;
}

class BomProjection {
  BomProjection({
    required this.sourceRevision,
    required List<BomArticleRow> articles,
    required List<ComponentRow> components,
    required List<Diagnostic> diagnostics,
  }) : articles = List.unmodifiable(articles),
       components = List.unmodifiable(components),
       diagnostics = List.unmodifiable(diagnostics);
  final int sourceRevision;
  final List<BomArticleRow> articles;
  final List<ComponentRow> components;
  final List<Diagnostic> diagnostics;
}

class _Total {
  int known = 0;
  final unknown = <String>{};
  void add(Component c) {
    final n = c.quantity.baseUnits;
    if (n == null) {
      unknown.add(c.id);
    } else {
      known += n;
    }
  }

  QuantityTotal build() =>
      QuantityTotal(knownBaseUnits: known, unknownComponentIds: unknown);
}

class _ArticleRow {
  _ArticleRow(this.key, this.article, this.unit);
  final String key;
  final Article? article;
  final QuantityUnit unit;
  final ids = <String>[];
  final designations = <String>[];
  final installed = _Total(),
      spare = _Total(),
      available = _Total(),
      included = _Total(),
      purchase = _Total(),
      total = _Total();
  void add(Component c, String designation) {
    ids.add(c.id);
    if (designation.isNotEmpty) designations.add(designation);
    total.add(c);
    (c.usage == ComponentUsage.installed ? installed : spare).add(c);
    switch (c.procurement.source) {
      case ProcurementSource.available:
        available.add(c);
      case ProcurementSource.included:
        included.add(c);
      case ProcurementSource.purchase:
        purchase.add(c);
    }
  }

  BomArticleRow build() => BomArticleRow(
    rowKey: key,
    article: article,
    unit: unit,
    componentIds: ids..sort(),
    designations: designations..sort(naturalCompare),
    installed: installed.build(),
    spare: spare.build(),
    available: available.build(),
    included: included.build(),
    toPurchase: purchase.build(),
    requiredTotal: total.build(),
  );
}

bool _visibleInMountingView(RectUnits boundsMm, Sheet sheet) {
  final view = sheet.mountingView!;
  final transform = MountingTransform(sheet, view);
  final topLeft = transform.toMountingMm(view.viewport.topLeft);
  final bottomRight = transform.toMountingMm(
    Vec2(
      view.viewport.x + view.viewport.width,
      view.viewport.y + view.viewport.height,
    ),
  );
  const toleranceMm = 1e-8;
  return boundsMm.x < bottomRight.x - toleranceMm &&
      boundsMm.x + boundsMm.width > topLeft.x + toleranceMm &&
      boundsMm.y < bottomRight.y - toleranceMm &&
      boundsMm.y + boundsMm.height > topLeft.y + toleranceMm;
}

BomProjection buildBom(EcadProject project) {
  final diagnostics = validateProject(project);
  final errors = diagnostics.where(
    (d) => d.severity == DiagnosticSeverity.error,
  );
  if (errors.isNotEmpty)
    throw EcadException(errors.first.message, code: errors.first.code);
  final resolver = ProjectResolver(project);
  final articles = resolver.articles;
  final components = resolver.components;
  final occurrences = <String, List<({String sheetId, String deviceId})>>{};
  final views = <String, List<Sheet>>{};
  final visiblePlacements = <String, List<String>>{};
  final placements = <String, ({String layoutId, String placementId})>{};
  for (final sheet in project.pages) {
    for (final device in sheet.devices) {
      occurrences.putIfAbsent(device.componentId, () => []).add((
        sheetId: sheet.id,
        deviceId: device.id,
      ));
    }
    if (sheet.mountingView case final view?)
      views.putIfAbsent(view.layoutId, () => []).add(sheet);
  }
  for (final layout in project.mountingLayouts) {
    for (final p in layout.placements) {
      placements[p.componentId] = (layoutId: layout.id, placementId: p.id);
      final bounds = resolver.mountingBounds(p)!;
      visiblePlacements[p.componentId] = [
        for (final sheet in views[layout.id] ?? <Sheet>[])
          if (_visibleInMountingView(bounds, sheet)) sheet.id,
      ];
    }
  }
  final surfaceViews = <String, List<String>>{};
  for (final layout in project.mountingLayouts) {
    if (layout.surfaceComponentId case final id?)
      surfaceViews.putIfAbsent(id, () => []).addAll([
        for (final sheet in views[layout.id] ?? <Sheet>[])
          if (_visibleInMountingView(
            RectUnits(
              x: 0,
              y: 0,
              width: layout.widthMm,
              height: layout.heightMm,
            ),
            sheet,
          ))
            sheet.id,
      ]);
  }
  final grouped = <String, _ArticleRow>{};
  final rows = <ComponentRow>[];
  for (final c in project.components) {
    final article = articles[c.articleId];
    final key =
        article == null
            ? 'component:${c.id}'
            : 'article:${article.id}:${c.quantity.unit.name}';
    grouped
        .putIfAbsent(key, () => _ArticleRow(key, article, c.quantity.unit))
        .add(c, resolver.fullDesignation(c));
    final placement = placements[c.id];
    rows.add(
      ComponentRow(
        component: c,
        article: article,
        occurrences: occurrences[c.id] ?? [],
        mountingSheetIds:
            {...?visiblePlacements[c.id], ...?surfaceViews[c.id]}.toList(),
        layoutId: placement?.layoutId,
        placementId: placement?.placementId,
        includedInDesignation:
            components[c.procurement.includedInComponentId] == null
                ? null
                : resolver.fullDesignation(
                  components[c.procurement.includedInComponentId]!,
                ),
      ),
    );
  }
  rows.sort((a, b) {
    final order = naturalCompare(
      resolver.fullDesignation(a.component),
      resolver.fullDesignation(b.component),
    );
    return order != 0 ? order : a.component.id.compareTo(b.component.id);
  });
  final result =
      grouped.values.map((r) => r.build()).toList()..sort((a, b) {
        if (a.article == null && b.article != null) return 1;
        if (a.article != null && b.article == null) return -1;
        final left = [
          a.article?.manufacturer ?? '',
          a.article?.partNumber ?? '',
          a.article?.name ?? '',
          a.designations.join(','),
        ];
        final right = [
          b.article?.manufacturer ?? '',
          b.article?.partNumber ?? '',
          b.article?.name ?? '',
          b.designations.join(','),
        ];
        for (var i = 0; i < left.length; i++) {
          final order = naturalCompare(left[i], right[i]);
          if (order != 0) return order;
        }
        return a.rowKey.compareTo(b.rowKey);
      });
  return BomProjection(
    sourceRevision: project.revision,
    articles: result,
    components: rows,
    diagnostics: diagnostics,
  );
}

int naturalCompare(String a, String b) {
  final parts = RegExp(r'[0-9]+|[^0-9]+');
  final left = parts.allMatches(a.toLowerCase()).map((m) => m[0]!).toList();
  final right = parts.allMatches(b.toLowerCase()).map((m) => m[0]!).toList();
  final numeric = RegExp(r'^[0-9]');
  final zeroes = RegExp(r'^0+');
  for (var i = 0; i < left.length && i < right.length; i++) {
    var order = left[i].compareTo(right[i]);
    if (numeric.hasMatch(left[i]) && numeric.hasMatch(right[i])) {
      final ln = left[i].replaceFirst(zeroes, '');
      final rn = right[i].replaceFirst(zeroes, '');
      order = ln.length.compareTo(rn.length);
      if (order == 0) order = ln.compareTo(rn);
    }
    if (order != 0) return order;
  }
  return left.length.compareTo(right.length);
}

class ReportRow {
  ReportRow({
    required this.sourceKey,
    required List<String> componentIds,
    required List<String> cells,
  }) : componentIds = List.unmodifiable(componentIds),
       cells = List.unmodifiable(cells);
  final String sourceKey;
  final List<String> componentIds;
  final List<String> cells;
}

class ReportData {
  ReportData({
    required this.sourceRevision,
    required this.sheetId,
    required this.spec,
    required List<String> columns,
    required List<ReportRow> rows,
    required List<Diagnostic> diagnostics,
  }) : columns = List.unmodifiable(columns),
       rows = List.unmodifiable(rows),
       diagnostics = List.unmodifiable(diagnostics);
  final int sourceRevision;
  final String sheetId;
  final BomTableSpec spec;
  final List<String> columns;
  final List<ReportRow> rows;
  final List<Diagnostic> diagnostics;
}

final _reportData = Expando<Map<String, ReportData>>();

ReportData buildReport(EcadProject project, Sheet sheet) {
  final spec = sheet.report;
  if (spec == null ||
      sheet.type != SheetType.billOfMaterials ||
      !identical(project.sheetById(sheet.id), sheet))
    throw const EcadException(
      'Report sheet must belong to this project snapshot.',
      code: 'invalid_report',
    );
  return (_reportData[project] ??= {}).putIfAbsent(
    sheet.id,
    () => _buildReport(project, sheet),
  );
}

ReportData _buildReport(EcadProject project, Sheet sheet) {
  final spec = sheet.report!;
  final bom = buildBom(project);
  final resolver = ProjectResolver(project);
  final articleReport = spec.kind == BomReportKind.articles;
  String unit(QuantityUnit u) => u == QuantityUnit.piece ? 'ks' : 'm';
  String unassignedName(String id) {
    final component = project.componentById(id)!;
    final designation = resolver.fullDesignation(component).trim();
    return [
      if (designation.isNotEmpty) designation else id,
      component.description.trim(),
    ].where((s) => s.isNotEmpty).join(' · ');
  }

  return ReportData(
    sourceRevision: project.revision,
    sheetId: sheet.id,
    spec: spec,
    diagnostics: bom.diagnostics,
    columns:
        articleReport
            ? [
              'Výrobce',
              'Objednací označení',
              'Název / specifikace',
              'Jednotka',
              'Osazeno',
              'Rezerva',
              'K dispozici',
              'V dodávce',
              'Pořídit',
            ]
            : [
              'Označení / popis',
              'Artikl',
              'Množství',
              'Jednotka',
              'Účel',
              'Zdroj',
              'Součást dodávky',
              'Umístění',
              'Listy',
              'Poznámka',
            ],
    rows:
        articleReport
            ? [
              for (final r in bom.articles)
                ReportRow(
                  sourceKey: r.rowKey,
                  componentIds: r.componentIds,
                  cells: [
                    r.article?.manufacturer ?? '',
                    r.article?.partNumber ?? '',
                    r.article == null
                        ? unassignedName(r.componentIds.single)
                        : [
                          r.article!.name,
                          r.article!.specification,
                        ].where((s) => s.isNotEmpty).join(' · '),
                    unit(r.unit),
                    r.installed.display(r.unit),
                    r.spare.display(r.unit),
                    r.available.display(r.unit),
                    r.included.display(r.unit),
                    r.toPurchase.display(r.unit),
                  ],
                ),
            ]
            : [
              for (final r in bom.components)
                ReportRow(
                  sourceKey: r.component.id,
                  componentIds: [r.component.id],
                  cells: [
                    [
                      resolver.fullDesignation(r.component),
                      r.component.description,
                    ].where((s) => s.isNotEmpty).join(' · '),
                    r.article?.name ?? 'Bez artiklu',
                    _quantityCell(r.component.quantity.amount),
                    unit(r.component.quantity.unit),
                    r.component.usage == ComponentUsage.installed
                        ? 'Osazeno'
                        : 'Rezerva',
                    switch (r.component.procurement.source) {
                      ProcurementSource.available => 'K dispozici',
                      ProcurementSource.included => 'V dodávce',
                      ProcurementSource.purchase => 'Pořídit',
                    },
                    r.includedInDesignation ??
                        r.component.procurement.includedInComponentId ??
                        '',
                    r.component.location,
                    {
                      for (final id in [
                        ...r.occurrences.map((o) => o.sheetId),
                        ...r.mountingSheetIds,
                      ])
                        fullPageDesignation(project.sheetById(id)!),
                    }.join(', '),
                    r.component.note,
                  ],
                ),
            ],
  );
}
