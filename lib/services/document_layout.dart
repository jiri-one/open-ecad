// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/painting.dart';

import '../editor/drawing_graphics.dart';
import 'export_fonts.dart';
import 'frame_layout.dart';
import 'mounting_annotations.dart';
import 'report_layout.dart';
import 'schematic_annotations.dart';

class DocumentPage {
  DocumentPage._({
    required this.sheet,
    required this.index,
    required ({PreparedFrameLayout frame, String? error}) Function()
    prepareFrame,
    this.report,
    required List<String> Function() overlaps,
  }) : _prepareFrame = prepareFrame,
       _overlaps = overlaps;
  final Sheet sheet;
  final int index;
  final ReportPage? report;
  final ({PreparedFrameLayout frame, String? error}) Function() _prepareFrame;
  final List<String> Function() _overlaps;
  late final _prepared = _prepareFrame();
  PreparedFrameLayout get frame => _prepared.frame;
  String? get layoutError => _prepared.error;
  late final List<String> diagnostics = List.unmodifiable([
    if (layoutError case final error?) error,
    if (frame.overflowFieldIds.isNotEmpty)
      'Text přesahuje pole rámu: ${frame.overflowFieldIds.join(', ')}.',
    ..._overlaps(),
  ]);
  String get number => report?.number ?? fullPageDesignation(sheet);
  SizeMm get sizeMm => sheet.paperSizeMm;
}

class DocumentLayout {
  DocumentLayout(
    this.sourceRevision,
    List<DocumentPage> pages,
    Map<String, ReportLayout> reports,
  ) : pages = List.unmodifiable(pages),
      reports = Map.unmodifiable(reports);
  final int sourceRevision;
  final List<DocumentPage> pages;
  final Map<String, ReportLayout> reports;

  DocumentPage firstPageFor(String sheetId) =>
      pages.firstWhere((p) => p.sheet.id == sheetId);

  void requireExportable() {
    for (final page in pages) {
      if (page.layoutError case final error?) {
        throw FormatException('List ${page.number}: $error');
      }
    }
  }
}

final _cache = Expando<({ExportFonts? fonts, DocumentLayout layout})>();

DocumentLayout layoutDocument(EcadProject project) {
  requireValidProject(project);
  return _layoutDocument(project);
}

// Frame dialogs change only frame definitions, choices and document fields.
DocumentLayout previewDocumentFrames(
  EcadProject project, {
  required EcadProject source,
}) {
  validateProjectFrames(project);
  return _layoutDocument(project, reportSource: source);
}

DocumentLayout _layoutDocument(
  EcadProject project, {
  EcadProject? reportSource,
}) {
  final cached = reportSource == null ? _cache[project] : null;
  if (cached != null && identical(cached.fonts, ExportFonts.loaded)) {
    return cached.layout;
  }
  final reports = <String, ReportLayout>{};
  final geometries = <String, FrameGeometry>{};
  final drafts = <({Sheet sheet, ReportPage? report, String? error})>[];
  for (final sheet in project.pages) {
    geometries[sheet.id] = layoutFrameGeometry(
      sheet.paperSizeMm,
      resolveSheetFrame(project, sheet),
    );
    if (sheet.report != null) {
      try {
        final report = layoutReport(
          project,
          sheet,
          data:
              reportSource == null
                  ? null
                  : buildReport(
                    reportSource,
                    reportSource.sheetById(sheet.id)!,
                  ),
        );
        reports[sheet.id] = report;
        drafts.addAll(
          report.pages.map((p) => (sheet: sheet, report: p, error: null)),
        );
      } on FormatException catch (error) {
        drafts.add((sheet: sheet, report: null, error: error.message));
      }
    } else {
      drafts.add((sheet: sheet, report: null, error: null));
    }
  }
  final resolver = ProjectResolver(project);
  final overlaps = <String, List<String>>{};
  final pages = <DocumentPage>[];
  for (final (index, draft) in drafts.indexed) {
    final sheet = draft.sheet, report = draft.report;
    final geometry = geometries[sheet.id]!;
    pages.add(
      DocumentPage._(
        sheet: sheet,
        index: index,
        report: report,
        prepareFrame: () {
          try {
            return (
              frame: prepareFrameLayout(
                bindFrame(
                  geometry,
                  project,
                  sheet,
                  FramePageContext(
                    number: report?.number ?? fullPageDesignation(sheet),
                    documentIndex: index + 1,
                    documentCount: drafts.length,
                    sheetPageIndex: (report?.index ?? 0) + 1,
                    sheetPageCount: reports[sheet.id]?.pages.length ?? 1,
                  ),
                ),
              ),
              error: draft.error,
            );
          } on EcadException catch (failure) {
            return (
              frame: prepareFrameLayout(
                FrameLayout(geometry: geometry, texts: const []),
              ),
              error:
                  'Text rámu nelze připravit (${failure.code}). Zkraťte hodnoty nebo text polí šablony.',
            );
          }
        },
        overlaps:
            () => overlaps.putIfAbsent(
              sheet.id,
              () => _overlapDiagnostics(resolver, sheet, geometry),
            ),
      ),
    );
  }
  final result = DocumentLayout(project.revision, pages, reports);
  if (reportSource == null) {
    _cache[project] = (fonts: ExportFonts.loaded, layout: result);
  }
  return result;
}

List<String> _overlapDiagnostics(
  ProjectResolver resolver,
  Sheet sheet,
  FrameGeometry frame,
) {
  if (frame.borderRectMm == null) return const [];
  final area = frameContentUnits(sheet, frame);
  final content = Rect.fromLTWH(area.x, area.y, area.width, area.height);
  final outside = <String>{};
  void check(String id, Rect bounds) {
    if (!content.contains(bounds.topLeft) ||
        !content.contains(bounds.bottomRight)) {
      outside.add(id);
    }
  }

  for (final graphic in sheet.graphics) {
    final visual = DrawingVisual(graphic);
    check(graphic.id, visual.bounds);
    visual.dispose();
  }
  for (final device in sheet.devices) {
    final symbol = geometryFor(device);
    final corners = [
      for (final x in [-symbol.width / 2, symbol.width / 2])
        for (final y in [-symbol.height / 2, symbol.height / 2])
          device.position + Vec2(x, y).rotated(device.rotation),
    ];
    for (final p in corners) {
      check(device.id, Rect.fromLTWH(p.x, p.y, 0, 0));
    }
    for (final bounds in deviceAnnotationBounds(resolver, device)) {
      check(device.id, bounds);
    }
  }
  final devices = {for (final d in sheet.devices) d.id: d};
  final markers = {for (final m in sheet.continuations) m.id: m};
  final corners = {for (final c in sheet.corners) c.id: c};
  for (final wire in resolver.wires(sheet)) {
    for (final p in WireRouter.path(wire, devices, markers, corners)) {
      check(wire.id, Rect.fromLTWH(p.x, p.y, 0, 0));
    }
  }
  final continuationIndex = ContinuationIndex(resolver.project);
  for (final marker in sheet.continuations) {
    final rotation = switch (marker.direction) {
      PortSide.right => 0.0,
      PortSide.bottom => 90.0,
      PortSide.left => 180.0,
      PortSide.top => 270.0,
    };
    final extent = marker.glyph == ContinuationGlyph.earth ? 25.0 : 21.0;
    final halfHeight = marker.glyph == ContinuationGlyph.earth ? 11.0 : 7.0;
    for (final x in [-3.0, extent]) {
      for (final y in [-halfHeight, halfHeight]) {
        final p = marker.position + Vec2(x, y).rotated(rotation);
        check(marker.id, Rect.fromLTWH(p.x, p.y, 0, 0));
      }
    }
    for (final bounds in continuationAnnotationBounds(
      resolver.project,
      sheet,
      marker,
      continuationIndex,
    )) {
      check(marker.id, bounds);
    }
  }
  for (final corner in sheet.corners) {
    for (final p in corner.path) {
      check(corner.id, Rect.fromLTWH(p.x, p.y, 0, 0));
    }
  }
  if (sheet.mountingView case final view?) {
    final t = MountingTransform(sheet, view);
    final layout = resolver.project.mountingLayoutById(view.layoutId);
    if (layout != null) {
      final p = t.toSheet(Vec2.zero),
          q = t.toSheet(Vec2(layout.widthMm, layout.heightMm));
      check(layout.id, Rect.fromLTRB(p.x, p.y, q.x, q.y));
      for (final annotation in layoutMountingAnnotations(resolver, sheet)) {
        check(annotation.placementId, annotation.bounds);
      }
      if (view.showSurfaceDimensions) {
        final label = reportTextPainter(
          mountingSurfaceCaption(layout),
          mountingCaptionSize,
        );
        check(
          layout.id,
          Rect.fromLTWH(
            view.viewport.x,
            view.viewport.y + view.viewport.height + mountingCaptionGap,
            label.width,
            label.height,
          ),
        );
        label.dispose();
      }
    }
  }
  return [
    if (outside.isNotEmpty)
      'Objekty mimo využitelnou plochu rámu: ${outside.length}. Zkontrolujte překrytí rámu a výkresu.',
  ];
}
