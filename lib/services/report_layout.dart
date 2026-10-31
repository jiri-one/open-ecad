// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:math' as math;

import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/painting.dart';

const reportInk = Color(0xff1e293b);
const reportMuted = Color(0xff526276);
const reportGrid = Color(0xffbdc7d3);
const reportHeader = Color(0xffedf1f5);

TextPainter reportTextPainter(String text, double size, {bool bold = false}) =>
    TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: 'NotoSans',
          fontSize: size,
          fontWeight: bold ? FontWeight.w600 : FontWeight.w400,
          color: reportInk,
          height: 1.25,
        ),
      ),
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
    )..layout();

class ReportText {
  const ReportText({
    required this.text,
    required this.x,
    required this.baseline,
    required this.width,
    required this.ascent,
    required this.fontSize,
    this.bold = false,
    this.color = reportInk,
  });
  final String text;
  final double x, baseline, width, ascent, fontSize;
  final bool bold;
  final Color color;
}

class ReportBox {
  const ReportBox(this.rect, {this.fill});
  final Rect rect;
  final Color? fill;
}

class ReportRowFragment {
  ReportRowFragment({
    required this.rowIndex,
    required this.sourceKey,
    required this.startLine,
    required this.endLine,
    required this.lineCount,
    required List<List<String>> cells,
    required this.bounds,
  }) : cells = List.unmodifiable(cells.map(List<String>.unmodifiable));
  final int rowIndex, startLine, endLine, lineCount;
  final String sourceKey;
  final List<List<String>> cells;
  final Rect bounds;
  bool get continuesBefore => startLine > 0;
  bool get continuesAfter => endLine < lineCount;
}

class ReportPage {
  ReportPage({
    required this.sheetId,
    required this.index,
    required this.number,
    required this.sizeMm,
    required List<ReportText> texts,
    required List<ReportBox> boxes,
    required List<ReportRowFragment> rowFragments,
  }) : texts = List.unmodifiable(texts),
       boxes = List.unmodifiable(boxes),
       rowFragments = List.unmodifiable(rowFragments);
  final String sheetId, number;
  final int index;
  final SizeMm sizeMm;
  final List<ReportText> texts;
  final List<ReportBox> boxes;
  final List<ReportRowFragment> rowFragments;
}

class ReportLayout {
  ReportLayout(this.data, List<ReportPage> pages)
    : pages = List.unmodifiable(pages);
  final ReportData data;
  final List<ReportPage> pages;
}

// Paper millimetres keep table typography independent of schematic units.
ReportLayout layoutReport(EcadProject project, Sheet sheet) =>
    _ReportBuilder(project, sheet, buildReport(project, sheet)).build();

void paintReportPage(Canvas canvas, ReportPage page) {
  canvas.drawRect(
    Rect.fromLTWH(0, 0, page.sizeMm.width, page.sizeMm.height),
    Paint()..color = const Color(0xffffffff),
  );
  for (final box in page.boxes) {
    if (box.fill case final color?) {
      canvas.drawRect(box.rect, Paint()..color = color);
    }
    canvas.drawRect(
      box.rect,
      Paint()
        ..color = reportGrid
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.18,
    );
  }
  for (final text in page.texts) {
    final painter = reportTextPainter(
      text.text,
      text.fontSize,
      bold: text.bold,
    );
    painter.text = TextSpan(
      text: text.text,
      style: (painter.text! as TextSpan).style!.copyWith(color: text.color),
    );
    painter.layout();
    painter.paint(canvas, Offset(text.x, text.baseline - text.ascent));
    painter.dispose();
  }
}

class _Metrics {
  final _widths = <(String, double, bool), double>{};
  double width(String text, double size, bool bold) =>
      _widths.putIfAbsent((text, size, bold), () {
        final p = reportTextPainter(text, size, bold: bold);
        final width = p.width;
        p.dispose();
        return width;
      });

  List<String> wrap(String text, double available, double size, bool bold) {
    final lines = <String>[];
    for (final paragraph in text.split('\n')) {
      var line = '';
      for (var word in paragraph
          .split(RegExp(r'\s+'))
          .where((s) => s.isNotEmpty)) {
        final next = line.isEmpty ? word : '$line $word';
        if (width(next, size, bold) <= available) {
          line = next;
          continue;
        }
        if (line.isNotEmpty) lines.add(line);
        line = '';
        while (width(word, size, bold) > available) {
          final runes = word.runes.toList();
          var low = 1, high = runes.length;
          while (low < high) {
            final mid = (low + high + 1) ~/ 2;
            if (width(String.fromCharCodes(runes.take(mid)), size, bold) <=
                available) {
              low = mid;
            } else {
              high = mid - 1;
            }
          }
          final part = String.fromCharCodes(runes.take(low));
          if (width(part, size, bold) > available) {
            throw const FormatException('Sloupec reportu je příliš úzký.');
          }
          lines.add(part);
          word = String.fromCharCodes(runes.skip(low));
        }
        line = word;
      }
      lines.add(line);
    }
    return lines;
  }
}

class _Page {
  final texts = <ReportText>[];
  final boxes = <ReportBox>[];
  final fragments = <ReportRowFragment>[];
}

class _ReportBuilder {
  _ReportBuilder(this.project, this.sheet, this.data);
  final EcadProject project;
  final Sheet sheet;
  final ReportData data;
  final metrics = _Metrics();
  final pages = <_Page>[];
  static const margin = 10.0, padding = 1.8, size = 2.8, lineHeight = 3.9;
  late final width = sheet.paperSizeMm.width - margin * 2;
  late final bottom = sheet.paperSizeMm.height - 18;
  late final List<double> columns;
  late double bodyTop;
  var y = 0.0;
  _Page get page => pages.last;

  void text(
    String value,
    double x,
    double top, {
    double fontSize = size,
    bool bold = false,
    Color color = reportInk,
  }) {
    if (value.isEmpty) return;
    final p = reportTextPainter(value, fontSize, bold: bold);
    final ascent = p.computeDistanceToActualBaseline(TextBaseline.alphabetic);
    page.texts.add(
      ReportText(
        text: value,
        x: x,
        baseline: top + ascent,
        width: p.width,
        ascent: ascent,
        fontSize: fontSize,
        bold: bold,
        color: color,
      ),
    );
    p.dispose();
  }

  void newPage({bool table = true}) {
    pages.add(_Page());
    final title =
        data.spec.kind == BomReportKind.articles
            ? 'Kusovník'
            : 'Seznam komponent';
    text(title, margin, 8, fontSize: 4.5, bold: true);
    text(
      'Revize ${project.revision}',
      sheet.paperSizeMm.width - 48,
      10,
      color: reportMuted,
    );
    y = 19;
    if (table) header();
  }

  void header() {
    final headerLines = [
      for (var i = 0; i < columns.length; i++)
        metrics.wrap(data.columns[i], columns[i] - padding * 2, size, true),
    ];
    final height =
        headerLines.map((l) => l.length).reduce(math.max) * lineHeight +
        padding * 2;
    bodyTop = 19 + height;
    if (bottom - bodyTop < lineHeight + padding * 2 + 4) {
      throw const FormatException('Papír je příliš malý pro report.');
    }
    if (y + height + lineHeight + padding * 2 > bottom) {
      newPage(table: false);
    }
    cells(headerLines, y, height, fill: reportHeader, bold: true);
    y += height;
  }

  void cells(
    List<List<String>> values,
    double top,
    double height, {
    Color? fill,
    bool bold = false,
  }) {
    var x = margin;
    for (var c = 0; c < columns.length; c++) {
      page.boxes.add(
        ReportBox(Rect.fromLTWH(x, top, columns[c], height), fill: fill),
      );
      for (var l = 0; l < values[c].length; l++) {
        text(
          values[c][l],
          x + padding,
          top + padding + l * lineHeight,
          bold: bold,
        );
      }
      x += columns[c];
    }
  }

  void paragraph(String value, {bool bold = false}) {
    if (value.isEmpty) return;
    final lines = metrics.wrap(value, width - padding * 2, size, bold);
    for (final line in lines) {
      if (y + lineHeight + padding > bottom) newPage(table: false);
      text(line, margin + padding, y + padding, bold: bold);
      y += lineHeight;
    }
    y += padding * 2;
  }

  ReportLayout build() {
    final weights =
        data.spec.kind == BomReportKind.articles
            ? [12, 15, 30, 7, 8, 8, 10, 9, 9]
            : [19, 17, 8, 7, 9, 11, 11, 10, 9, 19];
    final sum = weights.reduce((a, b) => a + b);
    columns = weights.map((w) => width * w / sum).toList();
    if (width <= 0 || columns.any((w) => w <= padding * 2)) {
      throw const FormatException('Papír je příliš malý pro report.');
    }
    newPage(table: false);
    paragraph(project.name, bold: true);
    paragraph(
      data.spec.title.isEmpty ? sheet.name : data.spec.title,
      bold: true,
    );
    paragraph(data.spec.note);
    final usedArticleIds = project.components.map((c) => c.articleId).toSet();
    final incomplete =
        project.articles
            .where(
              (a) =>
                  usedArticleIds.contains(a.id) &&
                  ((a.manufacturer ?? '').trim().isEmpty ||
                      (a.partNumber ?? '').trim().isEmpty),
            )
            .length;
    final withoutArticle =
        project.components.where((c) => c.articleId == null).length;
    final unknown =
        project.components.where((c) => c.quantity.baseUnits == null).length;
    paragraph(
      'Neúplné artikly: $incomplete · Bez artiklu: $withoutArticle · Neurčená množství: $unknown',
    );
    header();
    if (data.rows.isEmpty) paragraph('Žádné položky.');
    for (var index = 0; index < data.rows.length; index++) {
      final row = data.rows[index];
      final lines = [
        for (var c = 0; c < columns.length; c++)
          metrics.wrap(row.cells[c], columns[c] - padding * 2, size, false),
      ];
      final count = lines.map((l) => l.length).reduce(math.max);
      final height = count * lineHeight + padding * 2;
      if (height <= bottom - bodyTop && y + height > bottom) newPage();
      var start = 0;
      while (start < count) {
        final markerHeight = start > 0 ? 4.0 : 0.0;
        var capacity =
            ((bottom - y - padding * 2 - markerHeight) / lineHeight).floor();
        if (capacity < 1) {
          newPage();
          continue;
        }
        if (start > 0) {
          text(
            'Řádek ${index + 1} - pokračování',
            margin + padding,
            y,
            fontSize: 2.4,
            color: reportMuted,
          );
          y += markerHeight;
        }
        final end = math.min(count, start + capacity);
        final fragmentCells = [
          for (final cell in lines) cell.skip(start).take(end - start).toList(),
        ];
        final fragmentHeight = (end - start) * lineHeight + padding * 2;
        cells(fragmentCells, y, fragmentHeight);
        page.fragments.add(
          ReportRowFragment(
            rowIndex: index,
            sourceKey: row.sourceKey,
            startLine: start,
            endLine: end,
            lineCount: count,
            cells: fragmentCells,
            bounds: Rect.fromLTWH(margin, y, width, fragmentHeight),
          ),
        );
        y += fragmentHeight;
        start = end;
        if (start < count) {
          text(
            'Řádek ${index + 1} pokračuje na další straně',
            margin,
            bottom + 2,
            fontSize: 2.4,
            color: reportMuted,
          );
          newPage();
        }
      }
    }
    final result = <ReportPage>[];
    for (var i = 0; i < pages.length; i++) {
      final p = pages[i];
      final number =
          i == 0
              ? fullPageDesignation(sheet)
              : '${fullPageDesignation(sheet)}.${i + 1}';
      final footer = 'List $number · Strana ${i + 1} / ${pages.length}';
      final painter = reportTextPainter(footer, size);
      final ascent = painter.computeDistanceToActualBaseline(
        TextBaseline.alphabetic,
      );
      p.texts.add(
        ReportText(
          text: footer,
          x: margin,
          baseline: sheet.paperSizeMm.height - 8,
          width: painter.width,
          ascent: ascent,
          fontSize: size,
          color: reportMuted,
        ),
      );
      painter.dispose();
      result.add(
        ReportPage(
          sheetId: sheet.id,
          index: i,
          number: number,
          sizeMm: sheet.paperSizeMm,
          texts: p.texts,
          boxes: p.boxes,
          rowFragments: p.fragments,
        ),
      );
    }
    return ReportLayout(data, result);
  }
}
