// SPDX-License-Identifier: GPL-3.0-or-later
import 'graphics.dart';
import 'model.dart';

/// Ordinary editable graphics with generic captions; nothing is filled from
/// or linked to the project data.
abstract final class SheetTemplates {
  /// Relative widths sum to 1.
  static const formColumns = <(String, double)>[
    ('Č.', 0.07),
    ('Označení', 0.2),
    ('Popis', 0.46),
    ('Poznámka', 0.27),
  ];
  static const formRows = 18;
  static const _ink = '#17212B';
  static const _captionSize = 11.0;

  /// Placed for the drawing area of a default 1100 × 780 framed sheet.
  static List<DrawingElement> blankForm() {
    const left = 65.0;
    const top = 124.0;
    const width = 970.0;
    const headerHeight = 30.0;
    const rowHeight = 26.0;
    const height = headerHeight + formRows * rowHeight;
    DrawingElement line(Vec2 at, Vec2 to, double strokeWidth) => DrawingElement(
      id: newId('graphic'),
      kind: DrawingKind.path,
      position: at,
      width: to.x,
      height: to.y,
      stroke: _ink,
      strokeWidth: strokeWidth,
      path: [
        PathSegment(verb: PathVerb.moveTo, points: const [Vec2.zero]),
        PathSegment(verb: PathVerb.lineTo, points: [to]),
      ],
    );

    final graphics = <DrawingElement>[
      DrawingElement(
        id: newId('graphic'),
        kind: DrawingKind.path,
        position: const Vec2(left, top),
        width: width,
        height: height,
        stroke: _ink,
        strokeWidth: 1.2,
        path: [
          PathSegment(verb: PathVerb.moveTo, points: const [Vec2.zero]),
          PathSegment(verb: PathVerb.lineTo, points: const [Vec2(width, 0)]),
          PathSegment(
            verb: PathVerb.lineTo,
            points: const [Vec2(width, height)],
          ),
          PathSegment(verb: PathVerb.lineTo, points: const [Vec2(0, height)]),
          PathSegment(verb: PathVerb.close),
        ],
      ),
      line(const Vec2(left, top + headerHeight), const Vec2(width, 0), 1.2),
      for (var row = 1; row < formRows; row++)
        line(
          Vec2(left, top + headerHeight + row * rowHeight),
          const Vec2(width, 0),
          0.5,
        ),
    ];
    var x = left;
    for (var index = 0; index < formColumns.length; index++) {
      final (caption, share) = formColumns[index];
      if (index > 0) {
        graphics.add(line(Vec2(x, top), const Vec2(0, height), 0.8));
      }
      graphics.add(
        DrawingElement(
          id: newId('graphic'),
          kind: DrawingKind.text,
          position: Vec2(x + 6, top + (headerHeight - _captionSize) / 2),
          width: _captionWidth(caption),
          height: _captionSize,
          fill: _ink,
          text: caption,
          fontSize: _captionSize,
          bold: true,
        ),
      );
      x += width * share;
    }
    return graphics;
  }

  // Renderers stretch text to its box. Approximate bundled Noto Sans SemiBold
  // advances so the captions keep their natural proportions.
  static double _captionWidth(String text) {
    var ems = 0.0;
    for (final char in text.split('')) {
      ems += switch (char) {
        'i' || 'j' || 'l' || 'í' || 'I' || 'J' => 0.3,
        'f' || 't' || 'r' || 'ř' || 'ť' => 0.41,
        'm' || 'w' || 'M' || 'W' => 0.9,
        '.' || ',' || ':' || ';' || ' ' => 0.27,
        _ when char.toUpperCase() == char && char.toLowerCase() != char => 0.65,
        _ => 0.58,
      };
    }
    return ems * _captionSize;
  }
}
