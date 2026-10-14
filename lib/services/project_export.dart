// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'dart:math' as math;

import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as raster;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'project_persistence.dart';

/// Original vector glyphs and editable vector exports, including every sheet.
/// Native paths and text remain vector content; imported PNGs stay embedded.
/// No screenshots, remote assets or external font requests are used.
class ProjectExportService {
  ProjectExportService({ProjectPersistence? persistence})
    : _persistence = persistence ?? ProjectPersistence();

  final ProjectPersistence _persistence;
  static const pageWidth = 1100.0;
  static const pageHeight = 780.0;

  /// An SVG with one framed sheet per vertical page. Select [sheetId] to export
  /// the active sheet only; omitting it exports the complete project.
  String svg(EcadProject project, {String? sheetId}) {
    final sheets = _sheets(project, sheetId);
    final width = sheets.fold<double>(
      0,
      (value, sheet) => math.max(value, sheet.width),
    );
    final height = sheets.fold<double>(
      0,
      (value, sheet) => value + sheet.height,
    );
    final buffer =
        StringBuffer()
          ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
          ..writeln(
            '<svg xmlns="http://www.w3.org/2000/svg" width="${_n(width)}" height="${_n(height)}" viewBox="0 0 ${_n(width)} ${_n(height)}">',
          )
          ..writeln('<title>${_xml(project.name)}</title>')
          ..writeln('<desc>${_xml(project.description)}</desc>');
    var offset = 0.0;
    for (var index = 0; index < sheets.length; index++) {
      buffer.writeln(
        '<svg x="0" y="${_n(offset)}" width="${_n(sheets[index].width)}" height="${_n(sheets[index].height)}" viewBox="0 0 ${_n(sheets[index].width)} ${_n(sheets[index].height)}">',
      );
      buffer.write(
        _sheetContent(
          project,
          sheets[index],
          project.pages.indexOf(sheets[index]) + 1,
        ),
      );
      buffer.writeln('</svg>');
      offset += sheets[index].height;
    }
    buffer.writeln('</svg>');
    return buffer.toString();
  }

  Future<Uint8List> pdf(EcadProject project, {String? sheetId}) async {
    final sheets = _sheets(project, sheetId);
    // pdf's SVG image reader expects a four-channel byte buffer, whereas PNG
    // permits RGB, grayscale and palette storage too. Normalize only this
    // transient export payload; the portable document keeps its original PNG.
    final pdfImages = <String, String>{};
    for (final sheet in sheets) {
      for (final graphic in sheet.graphics) {
        if (graphic.kind == DrawingKind.image) {
          pdfImages.putIfAbsent(
            graphic.imageData,
            () => _pdfPng(graphic.imageData),
          );
        }
      }
    }
    final regular = pw.Font.ttf(
      await rootBundle.load('assets/fonts/NotoSans-Regular.ttf'),
    );
    final bold = pw.Font.ttf(
      await rootBundle.load('assets/fonts/NotoSans-SemiBold.ttf'),
    );
    final document = pw.Document(
      title: project.name,
      subject: project.description,
      creator: 'Open ECAD',
      theme: pw.ThemeData.withFont(base: regular, bold: bold),
    );
    final regularPdf = regular.getFont(pw.Context(document: document.document));
    final boldPdf = bold.getFont(pw.Context(document: document.document));
    _TextMeasure measure(String text, bool isBold, double size) {
      final font = isBold ? boldPdf : regularPdf;
      final metrics = font.stringMetrics(text) * size;
      return _TextMeasure(
        metrics.advanceWidth,
        size,
        font.ascent / font.emptyLineHeight * size,
      );
    }

    for (final sheet in sheets) {
      final format =
          sheet.showFrame &&
                  sheet.width == pageWidth &&
                  sheet.height == pageHeight
              ? PdfPageFormat.a3.landscape
              : PdfPageFormat(sheet.width, sheet.height);
      final sheetSvg =
          '<svg xmlns="http://www.w3.org/2000/svg" width="${_n(sheet.width)}" height="${_n(sheet.height)}" viewBox="0 0 ${_n(sheet.width)} ${_n(sheet.height)}">'
          '${_sheetContent(project, sheet, project.pages.indexOf(sheet) + 1, measureText: measure, pdfImages: pdfImages, pdf: true)}</svg>';
      document.addPage(
        pw.Page(
          pageFormat: format,
          margin: pw.EdgeInsets.zero,
          build:
              (context) => pw.SvgImage(
                svg: sheetSvg,
                width: format.width,
                height: format.height,
                fit: pw.BoxFit.contain,
                customFontLookup:
                    (family, style, weight) =>
                        weight == '600' || weight == '700' || weight == 'bold'
                            ? bold
                            : regular,
              ),
        ),
      );
    }
    return document.save();
  }

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

  Future<String?> saveSvg(
    EcadProject project, {
    String? sheetId,
  }) => _persistence.saveBytes(
    Uint8List.fromList(utf8.encode(svg(project, sheetId: sheetId))),
    fileName:
        '${ProjectPersistence.safeFileName(project.name)}${sheetId == null ? '' : '-list'}.svg',
    mimeType: 'image/svg+xml',
    extension: 'svg',
  );

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

  List<Sheet> _sheets(EcadProject project, String? sheetId) {
    requireValidProject(project);
    if (sheetId == null) return project.pages;
    final selected =
        project.pages.where((sheet) => sheet.id == sheetId).toList();
    if (selected.isEmpty) {
      throw const FormatException('List pro export neexistuje.');
    }
    return selected;
  }

  String _sheetContent(
    EcadProject project,
    Sheet sheet,
    int pageNumber, {
    _TextMeasure Function(String, bool, double)? measureText,
    Map<String, String> pdfImages = const {},
    bool pdf = false,
  }) {
    final devices = {for (final device in sheet.devices) device.id: device};
    final routes = [
      for (final wire in sheet.wires) WireRouter.path(wire, devices),
    ];
    final bounds = _bounds(sheet, routes);
    const drawingLeft = 65.0;
    const drawingTop = 114.0;
    const drawingWidth = 970.0;
    const drawingHeight = 518.0;
    final nativeLayout = !sheet.showFrame || sheet.graphics.isNotEmpty;
    final scale =
        nativeLayout
            ? 1.0
            : math.min(
              1.0,
              math.min(
                drawingWidth / math.max(bounds.width, 1),
                drawingHeight / math.max(bounds.height, 1),
              ),
            );
    final dx =
        nativeLayout
            ? 0.0
            : drawingLeft +
                (drawingWidth - bounds.width * scale) / 2 -
                bounds.left * scale;
    final dy =
        nativeLayout
            ? 0.0
            : drawingTop +
                (drawingHeight - bounds.height * scale) / 2 -
                bounds.top * scale;
    final frameTransform =
        'scale(${_n(sheet.width / pageWidth)} ${_n(sheet.height / pageHeight)})';
    final buffer =
        StringBuffer()
          ..writeln(
            '<rect x="0" y="0" width="${_n(sheet.width)}" height="${_n(sheet.height)}" fill="#ffffff"/>',
          )
          ..writeln('<g font-family="Noto Sans" fill="#1e293b">');
    if (sheet.showFrame) {
      buffer
        ..writeln('<g transform="$frameTransform">')
        ..writeln(
          '<rect x="32" y="32" width="1036" height="716" fill="none" stroke="#6b7c91" stroke-width="1"/>',
        )
        ..writeln(
          '<text x="52" y="57" font-size="10" fill="#64748b" letter-spacing="1.4">${_xml(sheet.type.label.toUpperCase())}</text>',
        )
        ..writeln(
          '<text x="52" y="81" font-size="17" font-weight="600">${_xml(_clip(sheet.name, 86))}</text>',
        )
        ..writeln(
          '<text x="1046" y="57" text-anchor="end" font-size="10" fill="#64748b">OPEN ECAD</text>',
        )
        ..writeln('</g>');
    }
    buffer.writeln(
      '<g transform="translate(${_n(dx)} ${_n(dy)}) scale(${_n(scale)})">',
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

    for (final points in routes) {
      if (points.length < 2) continue;
      buffer.writeln(
        '<polyline points="${points.map((point) => '${_n(point.x)},${_n(point.y)}').join(' ')}" '
        'fill="none" stroke="#26374d" stroke-width="1.8" stroke-linejoin="round" stroke-linecap="round"/>',
      );
    }
    for (final device in sheet.devices) {
      final definition = SymbolCatalog.definitionFor(device.kind);
      final angle = device.rotation * math.pi / 180;
      final halfWidth =
          (definition.width * math.cos(angle).abs() +
              definition.height * math.sin(angle).abs()) /
          2;
      final labelX = device.position.x + halfWidth + 16;
      buffer
        ..writeln(
          '<g transform="translate(${_n(device.position.x)} ${_n(device.position.y)}) rotate(${_n(device.rotation)})" '
          'stroke="#26374d" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" fill="none">',
        )
        ..writeln(
          symbolSvg(
            device.kind,
            dcSupply: RegExp(
              r'\bdc\b',
              caseSensitive: false,
            ).hasMatch(device.rating),
          ),
        )
        ..writeln('</g>')
        ..writeln(
          '<text x="${_n(labelX)}" y="${_n(device.position.y - 5)}" font-size="12" font-weight="600">${_xml(device.designation)}</text>',
        );
      final subtitle =
          device.rating.isNotEmpty ? device.rating : _kindName(device.kind);
      buffer.writeln(
        '<text x="${_n(labelX)}" y="${_n(device.position.y + 11)}" font-size="9" fill="#526276">${_xml(subtitle)}</text>',
      );
      if (device.description.isNotEmpty) {
        final lines = _wrap(device.description, 45);
        for (var line = 0; line < lines.length; line++) {
          buffer.writeln(
            '<text x="${_n(labelX)}" y="${_n(device.position.y + 26 + 13 * line)}" font-size="9" fill="#526276">${_xml(lines[line])}</text>',
          );
        }
      }
    }
    buffer.writeln('</g>');
    if (sheet.showFrame) {
      buffer
        ..writeln('<g transform="$frameTransform">')
        ..writeln(
          '<path d="M32 674 H1068 M676 674 V748 M928 674 V748 M676 716 H1068" '
          'fill="none" stroke="#6b7c91" stroke-width="1"/>',
        )
        ..writeln(
          '<text x="52" y="697" font-size="9" fill="#64748b">PROJEKT</text>',
        )
        ..writeln(
          '<text x="52" y="720" font-size="16" font-weight="600">${_xml(_clip(project.name, 64))}</text>',
        )
        ..writeln(
          '<text x="52" y="737" font-size="9" fill="#64748b">${_xml(_clip(project.description, 105))}</text>',
        )
        ..writeln(
          '<text x="690" y="691" font-size="8" fill="#64748b">LIST</text>',
        )
        ..writeln(
          '<text x="690" y="707" font-size="11">${_xml(_clip(sheet.name, 35))}</text>',
        )
        ..writeln(
          '<text x="942" y="691" font-size="8" fill="#64748b">ČÍSLO LISTU</text>',
        )
        ..writeln(
          '<text x="942" y="707" font-size="12" font-weight="600">${_xml(sheet.number)}</text>',
        )
        ..writeln(
          '<text x="690" y="736" font-size="9" fill="#526276">Revize ${project.revision}</text>',
        )
        ..writeln(
          '<text x="942" y="736" font-size="9" fill="#526276">$pageNumber / ${project.pages.length}</text>',
        )
        ..writeln('</g>');
    }
    buffer.writeln('</g>');
    return buffer.toString();
  }

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

  _Bounds _bounds(Sheet sheet, List<List<Vec2>> routes) {
    if (sheet.devices.isEmpty) return const _Bounds(0, 0, 1, 1);
    var left = double.infinity;
    var top = double.infinity;
    var right = -double.infinity;
    var bottom = -double.infinity;
    void include(double x, double y) {
      left = math.min(left, x);
      right = math.max(right, x);
      top = math.min(top, y);
      bottom = math.max(bottom, y);
    }

    for (final device in sheet.devices) {
      final definition = SymbolCatalog.definitionFor(device.kind);
      final angle = device.rotation * math.pi / 180;
      final halfWidth =
          (definition.width * math.cos(angle).abs() +
              definition.height * math.sin(angle).abs()) /
          2;
      final halfHeight =
          (definition.height * math.cos(angle).abs() +
              definition.width * math.sin(angle).abs()) /
          2;
      include(
        device.position.x - halfWidth - 4,
        device.position.y - halfHeight - 4,
      );
      final descriptionLines = _wrap(device.description, 45);
      final longestDescription = descriptionLines.fold<int>(
        0,
        (longest, line) => math.max(longest, line.length),
      );
      final labelWidth = math.max(
        device.designation.length * 8.0,
        math.max(
          (device.rating.isEmpty
                  ? _kindName(device.kind).length
                  : device.rating.length) *
              6.0,
          longestDescription * 6.0,
        ),
      );
      include(
        device.position.x + halfWidth + 16 + labelWidth,
        device.position.y +
            math.max(halfHeight + 4, 26.0 + descriptionLines.length * 13),
      );
    }
    for (final route in routes) {
      for (final point in route) {
        include(point.x, point.y);
      }
    }
    return _Bounds(left, top, right - left, bottom - top);
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

  static String _kindName(DeviceKind kind) => switch (kind) {
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

  static List<String> _wrap(String text, int width) {
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

  /// Width 0 is the thinnest visible line in PDF, which the PDF writer keeps.
  /// SVG would not draw it, so standalone SVG uses one screen pixel instead.
  static String _strokeWidth(double width, {required bool pdf}) =>
      width == 0 && !pdf
          ? 'stroke-width="1" vector-effect="non-scaling-stroke"'
          : 'stroke-width="${_n(width)}"';

  static String _clip(String text, int length) =>
      text.length <= length ? text : '${text.substring(0, length - 1)}…';
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

class _Bounds {
  const _Bounds(this.left, this.top, this.width, this.height);
  final double left;
  final double top;
  final double width;
  final double height;
}
