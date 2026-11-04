// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:math' as math;

import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/widgets.dart' show StringCharacters;
import 'package:flutter/painting.dart';

class PreparedFrameLayout {
  PreparedFrameLayout(
    this.source,
    Set<String> overflowFieldIds, [
    List<PreparedFrameLine> lines = const [],
  ]) : overflowFieldIds = Set.unmodifiable(overflowFieldIds),
       lines = List.unmodifiable(lines);

  final FrameLayout source;
  final Set<String> overflowFieldIds;
  final List<PreparedFrameLine> lines;
}

class PreparedFrameLine {
  PreparedFrameLine({
    required this.slotIndex,
    required this.text,
    required this.clip,
    required this.offset,
    required this.baseline,
    required this.fontSize,
    required this.bold,
  });

  final int slotIndex;
  final String text;
  final Rect clip;
  final Offset offset;
  final double baseline, fontSize;
  final bool bold;
  Color? _color;
  TextPainter? _painter;

  void paint(Canvas canvas, Color color) {
    if (_color != color) {
      _painter?.dispose();
      _painter = _painterFor(text, fontSize, bold, color);
      _color = color;
    }
    _painter!.paint(canvas, offset);
  }
}

TextPainter _painterFor(String text, double size, bool bold, Color color) =>
    TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: 'NotoSans',
          fontSize: size,
          fontWeight: bold ? FontWeight.w600 : FontWeight.w400,
          color: color,
          height: 1.2,
        ),
      ),
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
    )..layout();

class _TextMetrics {
  _TextMetrics(this.size, this.bold);
  final double size;
  final bool bold;
  final widths = <String, double>{};
  late final double height = _measure('Mg', (p) => p.height);
  late final double ascent = _measure(
    'Mg',
    (p) => p.computeDistanceToActualBaseline(TextBaseline.alphabetic),
  );

  double _measure(String text, double Function(TextPainter) read) {
    final painter = _painterFor(text, size, bold, const Color(0xff1e293b));
    final result = read(painter);
    painter.dispose();
    return result;
  }

  double width(String text) =>
      widths.putIfAbsent(text, () => _measure(text, (p) => p.width));

  String ellipsize(String text, double available) {
    final chars = text.characters.toList();
    var low = 0, high = chars.length;
    while (low < high) {
      final mid = (low + high + 1) ~/ 2;
      if (width('${chars.take(mid).join()}…') <= available) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    return '${chars.take(low).join()}…';
  }

  List<String> wrap(String text, double available, double availableHeight) {
    final limit = math.max(1, (availableHeight / height).floor()) + 1;
    final result = <String>[];
    for (final paragraph in text.split(RegExp(r'\r\n|[\r\n\u2028\u2029]'))) {
      var line = '';
      for (var word in paragraph
          .split(RegExp(r'\s+'))
          .where((w) => w.isNotEmpty)) {
        final next = line.isEmpty ? word : '$line $word';
        if (width(next) <= available) {
          line = next;
          continue;
        }
        if (line.isNotEmpty) result.add(line);
        if (result.length >= limit) return result;
        while (word.isNotEmpty && width(word) > available) {
          final chars = word.characters.toList();
          var low = 1, high = chars.length;
          while (low < high) {
            final mid = (low + high + 1) ~/ 2;
            if (width(chars.take(mid).join()) <= available) {
              low = mid;
            } else {
              high = mid - 1;
            }
          }
          result.add(chars.take(low).join());
          if (result.length >= limit) return result;
          word = chars.skip(low).join();
        }
        line = word;
      }
      if (line.isNotEmpty || paragraph.isEmpty) result.add(line);
      if (result.length >= limit) return result;
    }
    return result;
  }
}

PreparedFrameLayout prepareFrameLayout(FrameLayout frame) {
  final lines = <PreparedFrameLine>[];
  final overflow = <String>{};
  for (final (index, field) in frame.texts.indexed) {
    final box = field.rectMm;
    final clip = Rect.fromLTWH(box.x, box.y, box.width, box.height);
    final text = _xmlSafeText(field.text);
    if (text.isEmpty) continue;
    var fontSize = field.fontSizeMm;
    var metrics = _TextMetrics(fontSize, field.bold);
    var wrapped = metrics.wrap(text, box.width, box.height);
    bool fits(_TextMetrics m, List<String> l) =>
        l.length * m.height <= box.height + 1e-6 &&
        l.every((s) => m.width(s) <= box.width + 1e-6);
    if (field.overflow == FrameTextOverflow.shrink && !fits(metrics, wrapped)) {
      var low = field.minFontSizeMm, high = fontSize;
      for (var i = 0; i < 12; i++) {
        final mid = (low + high) / 2;
        final candidate = _TextMetrics(mid, field.bold);
        if (fits(candidate, candidate.wrap(text, box.width, box.height))) {
          low = mid;
        } else {
          high = mid;
        }
      }
      fontSize = low;
      metrics = _TextMetrics(fontSize, field.bold);
      wrapped = metrics.wrap(text, box.width, box.height);
    }
    if (!fits(metrics, wrapped)) {
      overflow.add(field.id);
      final capacity = math.max(1, (box.height / metrics.height).floor());
      wrapped = wrapped.take(capacity).toList();
      wrapped[wrapped.length - 1] = metrics.ellipsize(wrapped.last, box.width);
    }
    final top =
        box.y + math.max(0, (box.height - wrapped.length * metrics.height) / 2);
    for (var i = 0; i < wrapped.length; i++) {
      final value = wrapped[i];
      final left =
          box.x +
          switch (field.align) {
            FrameTextAlign.left => 0.0,
            FrameTextAlign.center => (box.width - metrics.width(value)) / 2,
            FrameTextAlign.right => box.width - metrics.width(value),
          };
      final y = top + i * metrics.height;
      lines.add(
        PreparedFrameLine(
          slotIndex: index,
          text: value,
          clip: clip,
          offset: Offset(left, y),
          baseline: y + metrics.ascent,
          fontSize: fontSize,
          bold: field.bold,
        ),
      );
    }
  }
  return PreparedFrameLayout(frame, overflow, List.unmodifiable(lines));
}

void paintFrameLayout(
  Canvas canvas,
  PreparedFrameLayout frame, {
  Color color = const Color(0xff1e293b),
}) {
  for (final stroke in frame.source.geometry.strokesMm) {
    canvas.drawLine(
      Offset(stroke.fromMm.x, stroke.fromMm.y),
      Offset(stroke.toMm.x, stroke.toMm.y),
      Paint()
        ..color = color
        ..strokeWidth = stroke.widthMm,
    );
  }
  for (final line in frame.lines) {
    canvas.save();
    canvas.clipRect(line.clip);
    line.paint(canvas, color);
    canvas.restore();
  }
}

String frameLayoutSvg(PreparedFrameLayout frame, {String idPrefix = 'frame'}) {
  // Encoding every code point keeps arbitrary prefixes distinct and XML-safe.
  final prefix = 'f${idPrefix.runes.map((r) => r.toRadixString(16)).join('_')}';
  final buffer = StringBuffer('<g data-frame="true" fill="#1e293b">');
  for (final stroke in frame.source.geometry.strokesMm) {
    buffer.write(
      '<path d="M${_n(stroke.fromMm.x)} ${_n(stroke.fromMm.y)} L${_n(stroke.toMm.x)} ${_n(stroke.toMm.y)}" fill="none" stroke="#1e293b" stroke-width="${_n(stroke.widthMm)}"/>',
    );
  }
  final slots = <int>{};
  for (final line in frame.lines) {
    final id = '${prefix}_${line.slotIndex}';
    if (slots.add(line.slotIndex)) {
      buffer.write(
        '<defs><clipPath id="$id"><rect x="${_n(line.clip.left)}" y="${_n(line.clip.top)}" width="${_n(line.clip.width)}" height="${_n(line.clip.height)}"/></clipPath></defs>',
      );
    }
    buffer.write(
      '<g clip-path="url(#$id)"><text x="${_n(line.offset.dx)}" y="${_n(line.baseline)}" font-family="Noto Sans" font-size="${_n(line.fontSize)}" font-weight="${line.bold ? 600 : 400}">${_xml(line.text)}</text></g>',
    );
  }
  return '$buffer</g>';
}

String _n(double value) => value.toStringAsFixed(6);
String _xmlSafeText(String text) => String.fromCharCodes(
  text.runes.map(
    (r) =>
        r == 9 ||
                r == 10 ||
                r == 13 ||
                (r >= 32 && r <= 0xd7ff) ||
                (r >= 0xe000 && r <= 0xfffd) ||
                (r >= 0x10000 && r <= 0x10ffff)
            ? r
            : 0xfffd,
  ),
);
String _xml(String text) => text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');
