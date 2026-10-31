// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'dart:io';
import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/editor/schematic_canvas.dart';
import 'package:open_ecad/services/project_export.dart';
import 'wiring_fixtures.dart';

EcadProject maskedScene() {
  final p = wiringScene(withCorner: true), s = p.pages.single;
  return p.copyWith(
    pages: [
      s.copyWith(
        graphics: [
          DrawingElement(
            id: 'mask',
            kind: DrawingKind.path,
            position: const Vec2(450, 280),
            width: 60,
            height: 40,
            fill: '#ffffff',
            path: [
              PathSegment(verb: PathVerb.moveTo, points: const [Vec2(0, 0)]),
              PathSegment(verb: PathVerb.lineTo, points: const [Vec2(60, 0)]),
              PathSegment(verb: PathVerb.lineTo, points: const [Vec2(60, 40)]),
              PathSegment(verb: PathVerb.lineTo, points: const [Vec2(0, 40)]),
              PathSegment(verb: PathVerb.close),
            ],
          ),
          DrawingElement(
            id: 'text',
            kind: DrawingKind.text,
            position: const Vec2(450, 290),
            width: 60,
            height: 20,
            text: 'MASK',
            fontSize: 20,
            fill: '#ff0000',
          ),
        ],
      ),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'SVG draws open corners and final wire strokes above labels and masks',
    () {
      final svg = ProjectExportService().svg(maskedScene());
      final wireIndex = svg.indexOf('<polyline points="410,300 540,300"');
      expect(wireIndex, greaterThan(svg.indexOf('>MASK</text>')));
      expect(wireIndex, greaterThan(svg.lastIndexOf('</text>')));
      expect(
        svg,
        contains(
          '<polyline data-corner="c" points="410,300 400,300 400,310" fill="none"',
        ),
      );
      expect(
        RegExp('<polyline points="410,300 540,300"').allMatches(svg),
        hasLength(1),
      );
    },
  );

  test('PDF content paints the final wire after text operators', () async {
    final bytes = await ProjectExportService().pdf(maskedScene());
    final raw = latin1.decode(bytes);
    final streams = <String>[];
    for (final match in RegExp(
      r'stream\r?\n([\s\S]*?)\r?\nendstream',
    ).allMatches(raw)) {
      final body = latin1.encode(match[1]!);
      try {
        streams.add(latin1.decode(ZLibDecoder().convert(body)));
      } on Object {
        streams.add(match[1]!);
      }
    }
    final page =
        streams.where((s) => s.contains('BT') && s.contains('ET')).single;
    final wire = RegExp(
      r'410(?:\.0+)?\s+300(?:\.0+)?\s+m\s+540(?:\.0+)?\s+300(?:\.0+)?\s+l',
    ).firstMatch(page);
    expect(wire, isNotNull, reason: page);
    expect(wire!.start, greaterThan(page.lastIndexOf('ET')));
  });

  testWidgets(
    'canvas keeps the wire over a text mask and corners stay open paths',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final p = maskedScene(), viewport = SchematicViewportController();
      await tester.pumpWidget(
        MaterialApp(
          home: SchematicCanvas(
            sheet: p.pages.single,
            project: p,
            selectedIds: const {},
            mode: CanvasMode.select,
            showGrid: false,
            palette: const CanvasPalette(
              background: Colors.white,
              paper: Colors.white,
              ink: Colors.black,
              muted: Colors.black,
              grid: Colors.grey,
              selection: Colors.blue,
              wire: Colors.black,
              sheetBorder: Colors.black,
            ),
            controller: viewport,
            onSelectionChanged: (_) {},
            onMoveDevices: (_) {},
            onPlaceDevice: (_, _) {},
            onConnect: (_, _) {},
            onDeleteWire: (_) {},
          ),
        ),
      );
      viewport.reset();
      await tester.pump();
      final events = <String>[];
      Path? corner;
      expect(
        find
            .descendant(
              of: find.byType(SchematicCanvas),
              matching: find.byType(CustomPaint),
            )
            .first,
        paints..everything((method, arguments) {
          if (method == #drawParagraph) events.add('text');
          if (method == #drawPath) {
            final path = arguments[0] as Path, paint = arguments[1] as Paint;
            if (paint.style == PaintingStyle.fill) events.add('mask');
            if ((paint.strokeWidth - 1.35).abs() < 1e-3 &&
                paint.style == PaintingStyle.stroke) {
              events.add('wire');
            }
            if (path.getBounds() == const Rect.fromLTRB(400, 300, 410, 310)) {
              corner = path;
            }
          }
          return true;
        }),
      );
      expect(events.where((v) => v == 'wire'), hasLength(2));
      expect(events.indexOf('wire'), greaterThan(events.lastIndexOf('text')));
      expect(events.indexOf('wire'), greaterThan(events.lastIndexOf('mask')));
      expect(corner, isNotNull);
      final metrics = corner!.computeMetrics().single;
      expect(metrics.isClosed, isFalse);
      expect(metrics.length, closeTo(20, 1e-6));
    },
  );
}
