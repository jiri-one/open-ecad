// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'dart:math' as math;

import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as raster;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'document_layout.dart';
import 'export_fonts.dart';
import 'frame_layout.dart';
import 'project_persistence.dart';
import 'report_layout.dart';
import 'schematic_annotations.dart';
import 'mounting_annotations.dart';

class ProjectExportService {
  ProjectExportService({ProjectPersistence? persistence})
    : _persistence = persistence ?? ProjectPersistence();

  final ProjectPersistence _persistence;
  static const pageWidth = 1100.0;
  static const pageHeight = 780.0;

  String svg(EcadProject project, {String? sheetId}) {
    final document = layoutDocument(project)..requireExportable();
    final resolver = ProjectResolver(project);
    final pages = _pages(document, sheetId);
    final width = pages.map((p) => p.sizeMm.width).reduce(math.max);
    final height = pages.fold<double>(0, (h, p) => h + p.sizeMm.height);
    final buffer =
        StringBuffer()
          ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
          ..writeln(
            '<svg xmlns="http://www.w3.org/2000/svg" width="${_n(width)}mm" height="${_n(height)}mm" viewBox="0 0 ${_n(width)} ${_n(height)}">',
          )
          ..writeln('<title>${_xml(project.name)}</title>')
          ..writeln('<desc>${_xml(project.description)}</desc>')
          ..writeln(ExportFonts.loaded?.svgStyle ?? '');
    var offset = 0.0;
    for (final page in pages) {
      buffer
        ..writeln(
          '<svg data-sheet="${_xml(page.sheet.id)}" data-page="${_xml(page.number)}" x="0" y="${_n(offset)}" width="${_n(page.sizeMm.width)}" height="${_n(page.sizeMm.height)}" viewBox="0 0 ${_n(page.sizeMm.width)} ${_n(page.sizeMm.height)}">',
        )
        ..write(_pageContent(resolver, page, document.pages.length))
        ..writeln('</svg>');
      offset += page.sizeMm.height;
    }
    buffer.writeln('</svg>');
    return buffer.toString();
  }

  Future<Uint8List> pdf(EcadProject project, {String? sheetId}) async {
    final fonts = await ExportFonts.load();
    final layout = layoutDocument(project)..requireExportable();
    final resolver = ProjectResolver(project);
    final pages = _pages(layout, sheetId);
    final pdfImages = <String, String>{};
    for (final page in pages) {
      for (final graphic in page.sheet.graphics) {
        if (graphic.kind == DrawingKind.image) {
          pdfImages.putIfAbsent(
            graphic.imageData,
            () => _pdfPng(graphic.imageData),
          );
        }
      }
    }
    final regular = pw.Font.ttf(fonts.regular);
    final bold = pw.Font.ttf(fonts.bold);
    final document = pw.Document(
      title: project.name,
      subject: project.description,
      creator: 'Open ECAD',
      theme: pw.ThemeData.withFont(base: regular, bold: bold),
    );
    final context = pw.Context(document: document.document);
    final regularPdf = regular.getFont(context);
    final boldPdf = bold.getFont(context);
    final destinations = {
      for (final page in pages.where((p) => p.report == null))
        page.sheet.id: {
          for (final device in page.sheet.devices) device.id: device.position,
          for (final marker in page.sheet.continuations)
            marker.id: marker.position,
        },
    };
    final targetIds = destinations.values.expand((d) => d.keys).toSet();
    _TextMeasure measure(String text, bool isBold, double size) {
      final font = isBold ? boldPdf : regularPdf;
      return _TextMeasure(
        (font.stringMetrics(text) * size).advanceWidth,
        size,
        font.ascent / font.emptyLineHeight * size,
      );
    }

    for (final page in pages) {
      final format = PdfPageFormat(
        page.sizeMm.width * PdfPageFormat.mm,
        page.sizeMm.height * PdfPageFormat.mm,
      );
      final links = _PdfPageLinks(page.sheet, regularPdf, targetIds);
      if (page.report case final report?) {
        final reportLayout = layout.reports[page.sheet.id]!;
        for (final link in layoutReportNavigationLinks(
          resolver,
          reportLayout,
          report,
        )) {
          links.add(link.target.device.id, link.bounds, paperMm: true);
        }
      }
      final sheetSvg =
          '<svg xmlns="http://www.w3.org/2000/svg" width="${_n(page.sizeMm.width)}" height="${_n(page.sizeMm.height)}" viewBox="0 0 ${_n(page.sizeMm.width)} ${_n(page.sizeMm.height)}">'
          '${_pageContent(resolver, page, layout.pages.length, measureText: measure, pdfImages: pdfImages, pdf: true, links: links)}</svg>';
      document.addPage(
        pw.Page(
          pageFormat: format,
          margin: pw.EdgeInsets.zero,
          build: (context) {
            links.attach(context, destinations[page.sheet.id] ?? const {});
            return pw.SvgImage(
              svg: sheetSvg,
              width: format.width,
              height: format.height,
              fit: pw.BoxFit.fill,
              customFontLookup:
                  (family, style, weight) =>
                      weight == '600' || weight == '700' || weight == 'bold'
                          ? bold
                          : regular,
            );
          },
        ),
      );
    }
    return document.save();
  }

  List<DocumentPage> _pages(DocumentLayout document, String? sheetId) {
    final pages =
        document.pages
            .where((p) => sheetId == null || p.sheet.id == sheetId)
            .toList();
    if (pages.isEmpty) {
      throw const FormatException('List pro export neexistuje.');
    }
    return pages;
  }

  String _pageContent(
    ProjectResolver resolver,
    DocumentPage page,
    int pageCount, {
    _TextMeasure Function(String, bool, double)? measureText,
    Map<String, String> pdfImages = const {},
    bool pdf = false,
    _PdfPageLinks? links,
  }) {
    if (page.report case final report?) {
      return _reportSvg(
        report,
        frame: page.frame,
        idPrefix: 'page-${page.index}',
      );
    }
    final transform = SheetTransform(page.sheet);
    return '<rect width="${_n(page.sizeMm.width)}" height="${_n(page.sizeMm.height)}" fill="#ffffff"/>'
        '${frameLayoutSvg(page.frame, idPrefix: 'page-${page.index}')}<g transform="translate(${_n(transform.offsetMm.x)} ${_n(transform.offsetMm.y)}) scale(${_n(transform.mmPerUnit)})">'
        '${_sheetContent(resolver, page.sheet, page.index + 1, pageCount, measureText: measureText, pdfImages: pdfImages, pdf: pdf, links: links)}</g>';
  }

  String _reportSvg(
    ReportPage page, {
    required PreparedFrameLayout frame,
    required String idPrefix,
  }) {
    final buffer = StringBuffer(
      '<rect width="${_n(page.sizeMm.width)}" height="${_n(page.sizeMm.height)}" fill="#ffffff"/>',
    );
    buffer.write(frameLayoutSvg(frame, idPrefix: idPrefix));
    for (final box in page.boxes) {
      buffer.writeln(
        '<rect x="${_n(box.rect.left)}" y="${_n(box.rect.top)}" width="${_n(box.rect.width)}" height="${_n(box.rect.height)}" fill="${box.fill == null ? 'none' : _color(box.fill!)}" stroke="${_color(reportGrid)}" stroke-width="0.18"/>',
      );
    }
    for (final text in page.texts) {
      buffer.writeln(
        '<text x="${_n(text.x)}" y="${_n(text.baseline)}" font-family="Noto Sans" font-size="${_n(text.fontSize)}" font-weight="${text.bold ? '600' : '400'}" fill="${_color(text.color)}">${_xml(text.text)}</text>',
      );
    }
    return buffer.toString();
  }

  static String _color(Color color) =>
      '#${color.toARGB32().toRadixString(16).substring(2)}';

  static String _pdfPng(String data) {
    final bytes = base64Decode(data);
    if (bytes[24] == 8 && bytes[25] == 6) return data;
    final decoded = raster.decodePng(bytes);
    if (decoded == null) {
      throw const FormatException(
        'Vložený PNG obrázek nelze načíst pro export.',
      );
    }
    return base64Encode(
      raster.encodePng(
        decoded.convert(format: raster.Format.uint8, numChannels: 4),
      ),
    );
  }

  Future<String?> saveSvg(EcadProject project, {String? sheetId}) async {
    await ExportFonts.load();
    return _persistence.saveBytes(
      Uint8List.fromList(utf8.encode(svg(project, sheetId: sheetId))),
      fileName:
          '${ProjectPersistence.safeFileName(project.name)}${sheetId == null ? '' : '-list'}.svg',
      mimeType: 'image/svg+xml',
      extension: 'svg',
    );
  }

  Future<String?> savePdf(
    EcadProject project, {
    String? sheetId,
  }) async => _persistence.saveBytes(
    await pdf(project, sheetId: sheetId),
    fileName:
        '${ProjectPersistence.safeFileName(project.name)}${sheetId == null ? '' : '-list'}.pdf',
    mimeType: 'application/pdf',
    extension: 'pdf',
  );

  String _sheetContent(
    ProjectResolver resolver,
    Sheet sheet,
    int pageNumber,
    int pageCount, {
    _TextMeasure Function(String, bool, double)? measureText,
    Map<String, String> pdfImages = const {},
    bool pdf = false,
    _PdfPageLinks? links,
  }) {
    final devices = {for (final d in sheet.devices) d.id: d};
    final markers = {for (final m in sheet.continuations) m.id: m};
    final corners = {for (final c in sheet.corners) c.id: c};
    final routes = [
      for (final wire in resolver.wires(sheet))
        WireRouter.path(wire, devices, markers, corners),
    ];
    final buffer = StringBuffer(
      '<g font-family="Noto Sans" fill="#1e293b"><g>',
    );

    for (final graphic in sheet.graphics) {
      buffer.write(
        _graphicSvg(
          graphic,
          measureText: measureText,
          pdfImages: pdfImages,
          pdf: pdf,
        ),
      );
    }

    if (sheet.mountingView != null) {
      buffer.write(
        _mountingSvg(resolver, sheet, measureText: measureText, links: links),
      );
    }
    for (final marker in sheet.continuations) {
      buffer.write(_continuationSvg(resolver, sheet, marker, links: links));
    }
    for (final device in sheet.devices) {
      buffer.write(_deviceSvg(resolver, device, links: links));
    }
    for (final corner in sheet.corners) {
      buffer.writeln(
        '<polyline data-corner="${_xml(corner.id)}" points="${corner.path.map((p) => '${_n(p.x)},${_n(p.y)}').join(' ')}" fill="none" stroke="#26374d" stroke-width="1.8" stroke-linejoin="round"/>',
      );
    }
    for (final points in routes) {
      if (points.length < 2) continue;
      buffer.writeln(
        '<polyline points="${points.map((point) => '${_n(point.x)},${_n(point.y)}').join(' ')}" '
        'fill="none" stroke="#26374d" stroke-width="1.8" stroke-linejoin="round" stroke-linecap="round"/>',
      );
    }
    buffer.writeln('</g>');
    buffer.writeln('</g>');
    return buffer.toString();
  }

  String _deviceSvg(
    ProjectResolver resolver,
    Device device, {
    _PdfPageLinks? links,
  }) {
    final component = resolver.components[device.componentId]!;
    final article = resolver.articles[component.articleId];
    final geometry = geometryFor(device);
    final bounds = rotatedBounds(
      device.position,
      geometry.width,
      geometry.height,
      device.rotation,
    );
    final labels = layoutPortAnnotations(resolver, device);
    final labelX = labels.fold<double>(
      bounds.x + bounds.width + 16,
      (x, label) => math.max(x, label.bounds.right + 12),
    );
    final buffer =
        StringBuffer()..writeln(
          '<g data-device="${_xml(device.id)}" transform="translate(${_n(device.position.x)} ${_n(device.position.y)}) rotate(${_n(device.rotation)})" stroke="#26374d" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" fill="none">',
        );
    switch (device.symbol) {
      case TerminalSymbolSpec(:final sides):
        final terminal = TerminalSymbolGeometry(
          sides: sides,
          center: device.position,
          quarterTurns: device.rotation ~/ 90,
        );
        final label = terminal.labelLayout();
        return '<g data-device="${_xml(device.id)}" stroke="#26374d" stroke-width="1.6" fill="none">'
            '${terminal.arms.map((a) => '<line x1="${_n(a.start.x)}" y1="${_n(a.start.y)}" x2="${_n(a.end.x)}" y2="${_n(a.end.y)}"/>').join()}'
            '<circle cx="${_n(terminal.center.x)}" cy="${_n(terminal.center.y)}" r="${_n(terminal.radius)}" fill="#ffffff"/>'
            '</g><text x="${_n(label.designationOrigin.x)}" y="${_n(label.designationOrigin.y + 10)}" font-size="11">${_xml(resolver.terminalStripLabel(component))}</text>'
            '<text x="${_n(label.numberOrigin.x)}" y="${_n(label.numberOrigin.y + 10)}" font-size="11">${_xml(component.terminal!.number)}</text>'
            '${_deviceReferencesSvg(resolver, device, links: links)}';
      case BuiltinSymbolSpec(:final kind):
        buffer.write(
          symbolSvg(
            kind,
            dcSupply: RegExp(
              r'\bdc\b',
              caseSensitive: false,
            ).hasMatch(article?.specification ?? ''),
          ),
        );
      case PortBlockSpec(:final width, :final height):
        buffer.writeln(
          '<rect x="${_n(-width / 2)}" y="${_n(-height / 2)}" width="${_n(width)}" height="${_n(height)}" fill="#ffffff"/>',
        );
    }
    buffer.writeln('</g>');
    for (final label in labels) {
      final p = label.port.geometry.point;
      final r = label.bounds;
      buffer
        ..writeln(
          '<circle cx="${_n(p.x)}" cy="${_n(p.y)}" r="2.4" fill="#ffffff" stroke="#26374d" stroke-width="1"/>',
        )
        ..writeln(
          '<rect x="${_n(r.left)}" y="${_n(r.top)}" width="${_n(r.width)}" height="${_n(r.height)}" fill="#ffffff"/>',
        );
      final lines = label.text.split('\n');
      for (var i = 0; i < lines.length; i++) {
        buffer.writeln(
          '<text x="${_n(r.left + 2)}" y="${_n(r.top + 9.5 + i * 11.25)}" font-size="9" fill="#26374d">${_xml(lines[i])}</text>',
        );
      }
    }
    buffer.writeln(
      '<text x="${_n(labelX)}" y="${_n(device.position.y - 5)}" font-size="12" font-weight="600">${_xml(resolver.fullDesignation(component))}</text>',
    );
    final function = component.electrical?.functionById(device.functionId);
    final subtitle = [
      if (device.mode == OccurrenceMode.reference) 'Reference',
      if (article?.specification.isNotEmpty ?? false)
        article!.specification
      else if (function != null)
        function.name
      else if (device.kind != null)
        schematicKindName(device.kind!),
    ].join(' · ');
    final lines = [
      ...wrapSchematicText(subtitle, 42),
      ...wrapSchematicText(component.description, 42),
    ];
    for (var i = 0; i < lines.length; i++) {
      buffer.writeln(
        '<text x="${_n(labelX)}" y="${_n(device.position.y + 11 + i * 13)}" font-size="9" fill="#526276">${_xml(lines[i])}</text>',
      );
    }
    final references = resolver.otherOccurrences(device);
    if (references.isNotEmpty) {
      buffer.write(
        _referenceTextSvg(
          [
            for (final target in references)
              (
                text:
                    '${fullPageDesignation(target.sheet)}${resolver.isMainFunction(target.device) ? ' (H)' : ''} · ${target.device.position.x}/${target.device.position.y}',
                destination: target.device.id,
              ),
          ],
          prefix: 'viz ',
          x: labelX,
          baseline: device.position.y + 11 + lines.length * 13,
          wrapWidth: 42,
          attributes: ' fill="#526276"',
          links: links,
        ),
      );
    }
    return buffer.toString();
  }

  String _deviceReferencesSvg(
    ProjectResolver resolver,
    Device device, {
    _PdfPageLinks? links,
  }) {
    final buffer = StringBuffer();
    for (final reference in layoutDeviceCrossReferences(resolver, device)) {
      links?.addText(
        reference.target.device.id,
        reference.text,
        reference.bounds.left,
        reference.baseline,
        8.5,
      );
      buffer.writeln(
        '<text data-cross-reference="${_xml(reference.target.device.id)}" x="${_n(reference.bounds.left)}" y="${_n(reference.baseline)}" font-size="8.5">${_xml(reference.text)}</text>',
      );
    }
    return buffer.toString();
  }

  String _continuationSvg(
    ProjectResolver resolver,
    Sheet sheet,
    ContinuationMarker marker, {
    _PdfPageLinks? links,
  }) {
    final angle = switch (marker.direction) {
      PortSide.right => 0,
      PortSide.bottom => 90,
      PortSide.left => 180,
      PortSide.top => 270,
    };
    final targets = <String, List<ContinuationTarget>>{};
    for (final target in ContinuationIndex(
      resolver.project,
    ).targets(sheetId: sheet.id, markerId: marker.id)) {
      (targets[fullPageDesignation(target.sheet)] ??= []).add(target);
    }
    final pages = targets.keys.toList()..sort(naturalCompare);
    final label = resolver.project.continuationLinkById(marker.linkId)!.label;
    final buffer =
        StringBuffer()
          ..writeln(
            '<g transform="translate(${_n(marker.position.x)} ${_n(marker.position.y)}) rotate($angle)" fill="none" stroke="#26374d" stroke-width="1.8">',
          )
          ..writeln(
            marker.glyph == ContinuationGlyph.earth
                ? '<path d="M0 0 H14 M14 -10 V10 M19 -7 V7 M24 -4 V4"/>'
                : '<path d="M0 0 H20 M13 -6 L20 0 L13 6"/>',
          )
          ..writeln('</g>');
    buffer.write(
      _referenceTextSvg(
        [
          if (pages.isEmpty) (text: 'bez protějšku', destination: null),
          for (final page in pages)
            (
              text: page,
              destination:
                  targets[page]!.length == 1
                      ? targets[page]!.single.marker.id
                      : null,
            ),
        ],
        prefix: '$label -> ',
        wholeDestination:
            pages.length == 1 && targets[pages.single]!.length == 1
                ? targets[pages.single]!.single.marker.id
                : null,
        x: marker.position.x + 8,
        baseline: marker.position.y - 12,
        wrapWidth: 48,
        upwards: true,
        links: links,
      ),
    );
    return buffer.toString();
  }

  String _referenceTextSvg(
    List<({String text, String? destination})> references, {
    required String prefix,
    required double x,
    required double baseline,
    required int wrapWidth,
    String? wholeDestination,
    bool upwards = false,
    String attributes = '',
    _PdfPageLinks? links,
  }) {
    final text = StringBuffer(prefix.replaceAll(RegExp(r'\s+'), ' '));
    final spans = <({int start, int end, String? destination})>[];
    for (final reference in references) {
      if (spans.isNotEmpty) text.write(', ');
      final start = text.length;
      text.write(reference.text.replaceAll(RegExp(r'\s+'), ' '));
      spans.add((
        start: start,
        end: text.length,
        destination: reference.destination,
      ));
    }
    final source = text.toString();
    if (wholeDestination != null) {
      spans
        ..clear()
        ..add((start: 0, end: source.length, destination: wholeDestination));
    }
    final lines = wrapSchematicText(source, wrapWidth);
    final buffer = StringBuffer();
    var offset = 0;
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final start = source.indexOf(line, offset);
      offset = start + line.length;
      final y = baseline + (upwards ? i + 1 - lines.length : i) * 13;
      buffer.writeln(
        '<text x="${_n(x)}" y="${_n(y)}" font-size="9"$attributes>${_xml(line)}</text>',
      );
      if (links == null) continue;
      for (final span in spans) {
        final from = math.max(start, span.start) - start;
        final to = math.min(offset, span.end) - start;
        if (from >= to || span.destination == null) continue;
        links.addText(
          span.destination!,
          line.substring(from, to),
          x + links.textWidth(line.substring(0, from), 9),
          y,
          9,
        );
      }
    }
    return buffer.toString();
  }

  String _mountingSvg(
    ProjectResolver resolver,
    Sheet sheet, {
    _TextMeasure Function(String, bool, double)? measureText,
    _PdfPageLinks? links,
  }) {
    final view = sheet.mountingView!;
    final layout = resolver.layouts[view.layoutId]!;
    final transform = MountingTransform(sheet, view);
    final scale = transform.unitsPerMm;
    final origin = transform.toSheet(Vec2.zero);
    final viewport = view.viewport;
    final clipId = 'mounting_${sheet.id}';
    final buffer =
        StringBuffer()
          ..writeln(
            '<defs><clipPath id="$clipId"><rect x="${_n(viewport.x)}" y="${_n(viewport.y)}" width="${_n(viewport.width)}" height="${_n(viewport.height)}"/></clipPath></defs>',
          )
          ..writeln('<g clip-path="url(#$clipId)">')
          ..writeln(
            '<rect data-surface="${_xml(layout.id)}" x="${_n(origin.x)}" y="${_n(origin.y)}" width="${_n(layout.widthMm * scale)}" height="${_n(layout.heightMm * scale)}" fill="none" stroke="#6b7c91" stroke-width="1.2"/>',
          );
    for (final placement in layout.placements) {
      final component = resolver.components[placement.componentId]!;
      final size = resolver.dimensionsFor(component);
      if (size.width == null || size.height == null) {
        throw const FormatException('Chybí rozměry umístěné komponenty.');
      }
      final center = transform.toSheet(placement.centerMm);
      final width = size.width! * scale, height = size.height! * scale;
      buffer.writeln(
        '<g data-placement="${_xml(placement.id)}" transform="translate(${_n(center.x)} ${_n(center.y)}) rotate(${_n(placement.rotation)})">'
        '<rect x="${_n(-width / 2)}" y="${_n(-height / 2)}" width="${_n(width)}" height="${_n(height)}" fill="#edf1f5" stroke="#26374d" stroke-width="1.2"/></g>',
      );
      if (view.showComponentDimensions) {
        final bounds = resolver.mountingBounds(placement)!;
        final bottom = transform.toSheet(
          Vec2(placement.centerMm.x, bounds.y + bounds.height),
        );
        buffer.writeln(
          '<text x="${_n(bottom.x)}" y="${_n(bottom.y + 12)}" text-anchor="middle" font-size="9" fill="#526276">${_n(size.width!)} × ${_n(size.height!)} mm</text>',
        );
      }
    }
    final annotations = layoutMountingAnnotations(resolver, sheet);
    for (final a in annotations) {
      if (a.leaderStart case final start?) {
        buffer.writeln(
          '<path d="M ${_n(start.dx)} ${_n(start.dy)} L ${_n(a.leaderEnd!.dx)} ${_n(a.leaderEnd!.dy)}" fill="none" stroke="#526276" stroke-width="0.7"/>',
        );
      }
    }
    for (final a in annotations) {
      final placement = layout.placements.firstWhere(
        (p) => p.id == a.placementId,
      );
      final target = resolver.schematicOccurrence(placement.componentId);
      if (target != null) {
        links?.add(
          target.device.id,
          a.bounds.intersect(
            Rect.fromLTWH(
              viewport.x,
              viewport.y,
              viewport.width,
              viewport.height,
            ),
          ),
        );
      }
      if (a.leaderStart != null) {
        final b = a.bounds.inflate(1);
        buffer.writeln(
          '<rect x="${_n(b.left)}" y="${_n(b.top)}" width="${_n(b.width)}" height="${_n(b.height)}" fill="#ffffff"/>',
        );
      }
      final measured = measureText?.call(a.text, true, mountingLabelSize).width;
      final correction =
          measured == null || measured == 0 ? 1.0 : a.textSize.width / measured;
      final at = a.textOrigin;
      buffer.writeln(
        '<g data-mounting-label="${_xml(a.placementId)}" transform="translate(${_n(at.dx)} ${_n(at.dy)}) rotate(${a.rotated ? -90 : 0}) scale(${_n(correction)} 1)">'
        '<text x="0" y="${_n(a.baseline)}" font-family="Noto Sans" font-size="${_n(mountingLabelSize)}" font-weight="600" textLength="${_n(a.textSize.width)}" lengthAdjust="spacingAndGlyphs">${_xml(a.text)}</text></g>',
      );
    }
    buffer.writeln('</g>');
    if (view.showSurfaceDimensions) {
      final caption = mountingSurfaceCaption(layout);
      final painter = reportTextPainter(caption, mountingCaptionSize);
      final baseline =
          viewport.y +
          viewport.height +
          mountingCaptionGap +
          painter.computeDistanceToActualBaseline(TextBaseline.alphabetic);
      painter.dispose();
      buffer.writeln(
        '<text x="${_n(viewport.x)}" y="${_n(baseline)}" font-size="11">${_xml(caption)}</text>',
      );
    }
    return buffer.toString();
  }

  String csv(EcadProject project, {required String sheetId}) {
    final sheet = project.sheetById(sheetId);
    if (sheet == null) {
      throw const FormatException('List pro export neexistuje.');
    }
    final data = buildReport(project, sheet);
    String row(List<String> cells) =>
        cells.map((cell) => '"${cell.replaceAll('"', '""')}"').join(',');
    return '${[row(data.columns), ...data.rows.map((r) => row(r.cells))].join('\r\n')}\r\n';
  }

  Future<String?> saveCsv(
    EcadProject project, {
    required String sheetId,
  }) => _persistence.saveBytes(
    Uint8List.fromList(utf8.encode('\ufeff${csv(project, sheetId: sheetId)}')),
    fileName: '${ProjectPersistence.safeFileName(project.name)}-kusovnik.csv',
    mimeType: 'text/csv',
    extension: 'csv',
  );

  String _graphicSvg(
    DrawingElement element, {
    _TextMeasure Function(String, bool, double)? measureText,
    Map<String, String> pdfImages = const {},
    bool pdf = false,
  }) {
    final buffer =
        StringBuffer()..writeln(
          '<g transform="translate(${_n(element.position.x)} ${_n(element.position.y)}) rotate(${_n(element.rotation)})" opacity="${_n(element.opacity)}">',
        );
    switch (element.kind) {
      case DrawingKind.path:
        final path = element.path
            .map((segment) {
              final command = switch (segment.verb) {
                PathVerb.moveTo => 'M',
                PathVerb.lineTo => 'L',
                PathVerb.cubicTo => 'C',
                PathVerb.close => 'Z',
              };
              return '$command${segment.points.map((point) => '${_n(point.x)} ${_n(point.y)}').join(' ')}';
            })
            .join(' ');
        buffer.writeln(
          '<path d="$path" fill="${element.fill ?? 'none'}" '
          'stroke="${element.stroke ?? 'none'}" ${_strokeWidth(element.strokeWidth, pdf: pdf)} '
          'stroke-linecap="${['butt', 'round', 'square'][element.lineCap]}" '
          'stroke-linejoin="${['miter', 'round', 'bevel'][element.lineJoin]}" '
          'fill-rule="${element.evenOdd ? 'evenodd' : 'nonzero'}"'
          '${element.dash.isEmpty ? '' : ' stroke-dasharray="${element.dash.map(_n).join(' ')}"'}/>',
        );
      case DrawingKind.text:
        final measure = measureText ?? _measureFlutterText;
        final lines = element.text.split('\n');
        final measurements = [
          for (final line in lines)
            measure(line, element.bold, element.fontSize),
        ];
        final naturalWidth = measurements.fold<double>(
          0,
          (value, item) => math.max(value, item.width),
        );
        final lineHeight = measurements.first.lineHeight;
        if (naturalWidth > 0 && lineHeight > 0) {
          buffer.writeln(
            '<g transform="scale(${_n(element.width / naturalWidth)} ${_n(element.height / (lineHeight * lines.length))})">',
          );
          for (var i = 0; i < lines.length; i++) {
            // The PDF SVG parser trims whitespace. Represent its advance with
            // x explicitly so significant indentation survives both exports.
            final leading = RegExp(r'^\s*').stringMatch(lines[i]) ?? '';
            final content = lines[i].trim();
            if (content.isEmpty) continue;
            final advance =
                measure(leading, element.bold, element.fontSize).width;
            final contentWidth =
                measure(content, element.bold, element.fontSize).width;
            buffer.writeln(
              '<text x="${_n(advance)}" y="${_n(measurements[i].ascent + i * lineHeight)}" '
              'font-family="Noto Sans" font-size="${_n(element.fontSize)}" '
              'font-weight="${element.bold ? '600' : '400'}" fill="${element.fill ?? element.stroke ?? '#000000'}" '
              'textLength="${_n(contentWidth)}" lengthAdjust="spacingAndGlyphs" xml:space="preserve">${_xml(content)}</text>',
            );
          }
          buffer.writeln('</g>');
        }
      case DrawingKind.image:
        buffer.writeln(
          '<image x="0" y="0" width="${_n(element.width)}" height="${_n(element.height)}" '
          'preserveAspectRatio="none" href="data:image/png;base64,${pdfImages[element.imageData] ?? element.imageData}"/>',
        );
    }
    buffer.writeln('</g>');
    return buffer.toString();
  }

  static _TextMeasure _measureFlutterText(String text, bool bold, double size) {
    final painter = TextPainter(
      text: TextSpan(
        text: text.isEmpty ? ' ' : text,
        style: TextStyle(
          fontFamily: 'NotoSans',
          fontSize: size,
          fontWeight: bold ? FontWeight.w600 : FontWeight.w400,
          height: 1,
          leadingDistribution: TextLeadingDistribution.proportional,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final result = _TextMeasure(
      text.isEmpty ? 0 : painter.width,
      painter.height,
      painter.computeDistanceToActualBaseline(TextBaseline.alphabetic),
    );
    painter.dispose();
    return result;
  }

  /// Centered glyph fragment. Port endpoints match [SymbolCatalog] exactly.
  static String symbolSvg(
    DeviceKind kind, {
    bool dcSupply = false,
  }) => switch (kind) {
    DeviceKind.supply =>
      '<circle cx="0" cy="-4" r="21" fill="#ffffff"/><path d="M0 17 V26 ${dcSupply ? 'M-8 -10 H8 M0 -18 V-2 M-8 6 H8' : 'M-12 -4 C-8 -14 -4 -14 0 -4 S8 6 12 -4'}"/>',
    DeviceKind.breaker =>
      '<path d="M0 -32 V-17 M0 17 V32 M0 -17 L16 10 M-7 -16 H7 M-7 17 H7 M-12 -10 H-5 V3 H-12 Z"/>',
    DeviceKind.threePoleBreaker || DeviceKind.threePoleDisconnector =>
      '<path d="${_switchPoles(const [-20, 0, 20], breaker: kind == DeviceKind.threePoleBreaker)}"/>'
          '<path d="M-14 -2.5 H26" stroke-dasharray="3 3"/>',
    DeviceKind.disconnector =>
      '<path d="${_switchPoles(const [0], breaker: false)}"/>',
    DeviceKind.fuse =>
      '<rect x="-6" y="-14" width="12" height="28" fill="#ffffff"/><path d="M0 -30 V30"/>',
    DeviceKind.contactor =>
      '<path d="M0 -32 V-16 M0 16 V32 M0 -16 L16 11 M-6 -16 H6 M-6 16 H6"/><path d="M-15 -14 V15" stroke-dasharray="3 3"/>',
    DeviceKind.motor =>
      '<path d="M0 -33 V-27 M27 0 H33"/><circle cx="0" cy="0" r="27" fill="#ffffff"/><text x="0" y="3" text-anchor="middle" fill="#26374d" stroke="none" font-size="23" font-weight="600">M</text><text x="0" y="18" text-anchor="middle" fill="#26374d" stroke="none" font-size="10">3~</text>',
    DeviceKind.transformer =>
      '<path d="M-10 -40 V-19.5 M10 -40 V-19.5 M-10 19.5 V40 M10 19.5 V40"/><circle cx="0" cy="-9" r="14.5" fill="#ffffff" stroke="none"/><circle cx="0" cy="9" r="14.5" fill="#ffffff" stroke="none"/><circle cx="0" cy="-9" r="14.5"/><circle cx="0" cy="9" r="14.5"/>',
    DeviceKind.currentTransformer =>
      '<circle cx="0" cy="0" r="14.5" fill="#ffffff"/><path d="M0 -30 V30 M-20 -10 H-10.5 M-20 10 H-10.5"/>',
    DeviceKind.terminal =>
      '<path d="M0 -16 V-7 M0 7 V16"/><circle cx="0" cy="0" r="7" fill="#ffffff"/>',
    DeviceKind.earth => '<path d="M0 -18 V0 M-18 0 H18 M-12 6 H12 M-6 12 H6"/>',
    DeviceKind.contactNo =>
      '<path d="M0 -30 V-14 M0 14 V30 M0 -14 L15 10"/><circle cx="0" cy="-14" r="2" fill="#ffffff"/><circle cx="0" cy="14" r="2" fill="#ffffff"/>',
    DeviceKind.contactNc =>
      '<path d="M0 -30 V-14 M0 14 V30 M0 14 H14 M0 -14 L16 18"/><circle cx="0" cy="-14" r="2" fill="#ffffff"/><circle cx="0" cy="14" r="2" fill="#ffffff"/>',
    DeviceKind.pushbuttonNo =>
      '<path d="M0 -30 V-14 M0 14 V30 M0 -14 L15 10 M-11 -8 H-14 V4 H-11"/><path d="M-14 -2 H7.5" stroke-dasharray="3 3"/><circle cx="0" cy="-14" r="2" fill="#ffffff"/><circle cx="0" cy="14" r="2" fill="#ffffff"/>',
    DeviceKind.coil =>
      '<path d="M0 -27 V-15 M0 15 V27"/><rect x="-21" y="-15" width="42" height="30" fill="#ffffff"/>',
    DeviceKind.lamp =>
      '<path d="M0 -28 V-19 M0 19 V28"/><circle cx="0" cy="0" r="19" fill="#ffffff"/><path d="M-13 -13 L13 13 M13 -13 L-13 13"/>',
    DeviceKind.ammeter || DeviceKind.voltmeter =>
      '<path d="M0 -30 V-15 M0 15 V30"/><circle cx="0" cy="0" r="15" fill="#ffffff"/><text x="0" y="6.5" text-anchor="middle" fill="#26374d" stroke="none" font-size="18">${kind == DeviceKind.ammeter ? 'A' : 'V'}</text>',
  };

  /// Lead ends must stay on the ±32 terminals of [SymbolCatalog] switches.
  static String _switchPoles(List<int> poles, {required bool breaker}) => [
    for (final x in poles)
      'M$x -32 V-16 M$x 16 V32 M$x -16 L${x + 12} 11 '
          '${breaker ? 'M${x - 3} 13 L${x + 3} 19 M${x - 3} 19 L${x + 3} 13' : 'M${x - 6} 16 H${x + 6}'}',
  ].join(' ');

  /// Width 0 is the thinnest visible line in PDF, which the PDF writer keeps.
  /// SVG would not draw it, so standalone SVG uses one screen pixel instead.
  static String _strokeWidth(double width, {required bool pdf}) =>
      width == 0 && !pdf
          ? 'stroke-width="1" vector-effect="non-scaling-stroke"'
          : 'stroke-width="${_n(width)}"';

  static String _n(num value) =>
      value.toStringAsFixed(6).replaceFirst(RegExp(r'\.?0+$'), '');
  static String _xml(String value) => value
      .replaceAll(RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f]'), '')
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');
}

class _TextMeasure {
  const _TextMeasure(this.width, this.lineHeight, this.ascent);
  final double width;
  final double lineHeight;
  final double ascent;
}

class _PdfPageLinks {
  _PdfPageLinks(this.sheet, this.font, this.targetIds);

  final Sheet sheet;
  final PdfFont font;
  final Set<String> targetIds;
  final _links = <({String destination, Rect bounds, bool paperMm})>[];

  double textWidth(String text, double size) =>
      font.stringMetrics(text).advanceWidth * size;

  void addText(
    String destination,
    String text,
    double x,
    double baseline,
    double size,
  ) {
    final metrics = font.stringMetrics(text) * size;
    add(
      destination,
      Rect.fromLTRB(
        x + math.min(0, metrics.left),
        baseline - metrics.bottom,
        x + math.max(metrics.advanceWidth, metrics.right),
        baseline - metrics.top,
      ).inflate(0.5),
    );
  }

  void add(String destination, Rect bounds, {bool paperMm = false}) {
    if (!targetIds.contains(destination) || bounds.isEmpty) return;
    _links.add((destination: destination, bounds: bounds, paperMm: paperMm));
  }

  void attach(pw.Context context, Map<String, Vec2> destinations) {
    final transform = SheetTransform(sheet);
    final height = sheet.paperSizeMm.height * PdfPageFormat.mm;
    final paper = Rect.fromLTWH(
      0,
      0,
      sheet.paperSizeMm.width * PdfPageFormat.mm,
      height,
    );
    for (final entry in destinations.entries) {
      final point = transform.toPdfPoints(entry.value);
      context.document.pdfNames.addDest(
        'ecad:${entry.key}',
        context.page,
        posX: point.x,
        posY: height - point.y,
      );
    }
    for (final link in _links) {
      Vec2 toPoints(double x, double y) =>
          link.paperMm
              ? Vec2(x, y) * PdfPageFormat.mm
              : transform.toPdfPoints(Vec2(x, y));
      final start = toPoints(link.bounds.left, link.bounds.top);
      final end = toPoints(link.bounds.right, link.bounds.bottom);
      final rect = Rect.fromLTRB(
        start.x,
        start.y,
        end.x,
        end.y,
      ).intersect(paper);
      if (rect.isEmpty) continue;
      PdfAnnot(
        context.page,
        PdfAnnotNamedLink(
          rect: PdfRect(
            rect.left,
            height - rect.bottom,
            rect.width,
            rect.height,
          ),
          dest: 'ecad:${link.destination}',
        ),
      );
    }
  }
}
