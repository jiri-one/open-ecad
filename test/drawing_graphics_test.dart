import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_ecad/editor/drawing_graphics.dart';
import 'package:open_ecad/services/project_export.dart';

const _redPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGO4o6HxHwAFPAIsDsQvxQAAAABJRU5ErkJggg==';

DrawingElement _rectangle({bool filled = false}) => DrawingElement(
  id: 'rectangle',
  kind: DrawingKind.path,
  position: const Vec2(30, 30),
  width: 360,
  height: 240,
  stroke: '#17212B',
  fill: filled ? '#E0E0E0' : null,
  strokeWidth: 1,
  lineCap: 1,
  lineJoin: 2,
  path: [
    PathSegment(verb: PathVerb.moveTo, points: [const Vec2(0, 0)]),
    PathSegment(verb: PathVerb.lineTo, points: [const Vec2(360, 0)]),
    PathSegment(verb: PathVerb.lineTo, points: [const Vec2(360, 240)]),
    PathSegment(verb: PathVerb.lineTo, points: [const Vec2(0, 240)]),
    PathSegment(verb: PathVerb.close),
  ],
);

EcadProject _project() => EcadProject(
  id: 'native',
  name: 'Native drawing',
  pages: [
    Sheet(
      id: 'native_page',
      name: 'Source page',
      number: '1',
      width: 420,
      height: 300,
      showFrame: false,
      sourcePage: 1,
      graphics: [
        _rectangle(),
        DrawingElement(
          id: 'curve',
          kind: DrawingKind.path,
          position: const Vec2(70, 130),
          width: 180,
          height: 100,
          stroke: '#224466',
          strokeWidth: 2,
          lineCap: 1,
          dash: [6, 3],
          evenOdd: true,
          path: [
            PathSegment(verb: PathVerb.moveTo, points: [const Vec2(0, 80)]),
            PathSegment(
              verb: PathVerb.cubicTo,
              points: [
                const Vec2(0, 0),
                const Vec2(180, 0),
                const Vec2(180, 80),
              ],
            ),
          ],
        ),
        DrawingElement(
          id: 'title',
          kind: DrawingKind.text,
          position: const Vec2(60, 60),
          width: 260,
          height: 25,
          text: 'Řízení <motor> & "1"',
          fontSize: 18,
          bold: true,
          fill: '#17212B',
        ),
        DrawingElement(
          id: 'vertical',
          kind: DrawingKind.text,
          position: const Vec2(350, 230),
          width: 120,
          height: 16,
          rotation: -90,
          text: 'Otáčení o 90°',
          fontSize: 12,
          fill: '#17212B',
        ),
        DrawingElement(
          id: 'image',
          kind: DrawingKind.image,
          position: const Vec2(280, 170),
          width: 35,
          height: 35,
          imageData: _redPng,
        ),
      ],
    ),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final loader =
        FontLoader('NotoSans')
          ..addFont(rootBundle.load('assets/fonts/NotoSans-Regular.ttf'))
          ..addFont(rootBundle.load('assets/fonts/NotoSans-SemiBold.ttf'));
    await loader.load();
  });

  test(
    'PDF em-height text keeps glyph size instead of shrinking by font line leading',
    () async {
      final graphic = DrawingElement(
        id: 'em',
        kind: DrawingKind.text,
        position: const Vec2(10, 10),
        width: 20,
        height: 20,
        text: 'M',
        fontSize: 20,
        fill: '#000000',
      );
      final visual = DrawingVisual(graphic);
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder)..drawColor(Colors.white, BlendMode.src);
      visual.paint(canvas, ink: Colors.black, paper: Colors.white);
      final picture = recorder.endRecording();
      final image = await picture.toImage(50, 50);
      final pixels = (await image.toByteData())!;
      final inkRows = <int>{};
      for (var y = 0; y < 50; y++) {
        for (var x = 0; x < 50; x++) {
          if (pixels.getUint8((y * 50 + x) * 4) < 128) inkRows.add(y);
        }
      }
      expect(inkRows.length, greaterThanOrEqualTo(13));
      expect(inkRows.length, lessThanOrEqualTo(16));
      image.dispose();
      picture.dispose();
      visual.dispose();
    },
  );

  test(
    'subpixel source strokes remain visible on canvas without changing stored width',
    () async {
      final graphic = DrawingElement(
        id: 'thin',
        kind: DrawingKind.path,
        position: const Vec2(5, 10),
        width: 30,
        height: 0,
        stroke: '#000000',
        strokeWidth: .00315,
        path: [
          PathSegment(verb: PathVerb.moveTo, points: [const Vec2(0, 0)]),
          PathSegment(verb: PathVerb.lineTo, points: [const Vec2(30, 0)]),
        ],
      );
      final visual = DrawingVisual(graphic);
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder)..drawColor(Colors.white, BlendMode.src);
      visual.paint(canvas, ink: Colors.black, paper: Colors.white);
      final picture = recorder.endRecording();
      final image = await picture.toImage(40, 20);
      final pixels = (await image.toByteData())!;
      var darkness = 0;
      for (var offset = 0; offset < pixels.lengthInBytes; offset += 4) {
        darkness += 255 - pixels.getUint8(offset);
      }
      expect(darkness, greaterThan(30 * 100));
      expect(graphic.strokeWidth, .00315);
      image.dispose();
      picture.dispose();
      visual.dispose();
    },
  );

  test(
    'path picking and marquee distinguish strokes, fills, curves and rotation',
    () {
      final outline = DrawingVisual(_rectangle());
      expect(outline.hitTest(const Offset(100, 100), 3), isFalse);
      expect(outline.hitTest(const Offset(30, 100), 3), isTrue);
      expect(outline.intersects(const Rect.fromLTWH(80, 80, 40, 40)), isFalse);
      expect(outline.intersects(const Rect.fromLTWH(25, 80, 10, 40)), isTrue);
      final filled = DrawingVisual(_rectangle(filled: true));
      expect(filled.hitTest(const Offset(100, 100), 3), isTrue);
      expect(filled.intersects(const Rect.fromLTWH(80, 80, 40, 40)), isTrue);
      final curve = DrawingVisual(_project().pages.single.graphics[1]);
      expect(curve.hitTest(const Offset(160, 150), 3), isTrue);
      expect(curve.hitTest(const Offset(160, 200), 3), isFalse);
      final text = DrawingVisual(_project().pages.single.graphics[3]);
      expect(text.hitTest(const Offset(358, 160), 1), isTrue);
      expect(text.hitTest(const Offset(390, 160), 1), isFalse);
      expect(text.bounds.top, closeTo(109.5, .001));
      for (final visual in [outline, filled, curve, text]) {
        visual.dispose();
      }
    },
  );

  test('even-odd holes remain empty and rendered colors stay native', () async {
    final rectangle = _rectangle(filled: true);
    final hole = rectangle.copyWith(
      evenOdd: true,
      path: [
        ...rectangle.path,
        PathSegment(verb: PathVerb.moveTo, points: [const Vec2(80, 60)]),
        PathSegment(verb: PathVerb.lineTo, points: [const Vec2(180, 60)]),
        PathSegment(verb: PathVerb.lineTo, points: [const Vec2(180, 160)]),
        PathSegment(verb: PathVerb.lineTo, points: [const Vec2(80, 160)]),
        PathSegment(verb: PathVerb.close),
      ],
    );
    final visual = DrawingVisual(hole);
    expect(visual.hitTest(const Offset(160, 140), 1), isFalse);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawColor(Colors.white, BlendMode.src);
    visual.paint(canvas, ink: Colors.black, paper: Colors.white);
    final picture = recorder.endRecording();
    final image = await picture.toImage(420, 300);
    final pixels = (await image.toByteData())!;
    int redAt(int x, int y) => pixels.getUint8((y * 420 + x) * 4);
    expect(redAt(50, 50), 224);
    expect(redAt(160, 140), 255);
    image.dispose();
    picture.dispose();
    visual.dispose();
  });

  test(
    'embedded PNG cache decodes asynchronously and releases on page change',
    () async {
      final cache = DrawingImageCache();
      final image = _project().pages.single.graphics.last;
      final decoded = Future<void>(() async {
        while (cache.imageFor(image) == null) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      });
      cache.update([image]);
      await decoded.timeout(const Duration(seconds: 5));
      expect(cache.imageFor(image)!.width, 1);
      cache.update(const []);
      expect(cache.imageFor(image), isNull);
      cache.dispose();
    },
  );

  test(
    'SVG exports editable source geometry, styles, images and escaped text without a second frame',
    () {
      final exporter = ProjectExportService();
      final svg = exporter.svg(_project());
      expect(svg, contains('width="420" height="300" viewBox="0 0 420 300"'));
      expect(svg, contains('translate(70 130) rotate(0)'));
      expect(svg, contains('C0 0 180 0 180 80'));
      expect(svg, contains('stroke-linecap="round"'));
      expect(svg, contains('stroke-linejoin="bevel"'));
      expect(svg, contains('fill-rule="evenodd"'));
      expect(svg, contains('stroke-dasharray="6 3"'));
      expect(svg, contains('Řízení &lt;motor&gt; &amp; &quot;1&quot;'));
      expect(svg, contains('rotate(-90)'));
      expect(svg, contains('href="data:image/png;base64,$_redPng"'));
      expect(svg, isNot(contains('ELEKTRICKÉ SCHÉMA')));
      expect(svg, isNot(contains('OPEN ECAD')));
      final mixed = _project().copyWith(
        pages: [
          ..._project().pages,
          Sheet(
            id: 'other',
            name: 'Other',
            number: '2',
            width: 200,
            height: 500,
            showFrame: false,
          ),
        ],
      );
      final mixedSvg = exporter.svg(mixed);
      expect(
        mixedSvg,
        contains('width="420" height="800" viewBox="0 0 420 800"'),
      );
      expect(mixedSvg, contains('<svg x="0" y="300" width="200" height="500"'));
    },
  );

  test(
    'PDF preserves native page dimensions, text and image objects',
    () async {
      final exporter = ProjectExportService();
      final project = _project();
      final bytes = await exporter.pdf(project);
      final content = latin1.decode(bytes);
      expect(content, startsWith('%PDF-'));
      expect(content, matches(RegExp(r'/MediaBox\s*\[0 0 420 300\]')));
      expect(content, contains('/Subtype/Image'));
      if (const bool.fromEnvironment('GRAPHICS_EXPORT_QA')) {
        File('/tmp/open-ecad-graphics-qa.pdf').writeAsBytesSync(bytes);
        File(
          '/tmp/open-ecad-graphics-qa.svg',
        ).writeAsStringSync(exporter.svg(project));
      }
    },
  );

  test(
    'PDF normalizes RGB and grayscale PNGs without changing source image data',
    () async {
      const images = [
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGO4o6EBAAMQAS0ujiXaAAAAAElFTkSuQmCC',
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAAAAAA6fptVAAAACklEQVR4nGOoAAAAegB5s2G1ewAAAABJRU5ErkJggg==',
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR4nGOo+A8AAfIBeADnajQAAAAASUVORK5CYII=',
      ];
      final original = _project();
      final page = original.pages.single;
      final sourceImage = page.graphics.last;
      final exporter = ProjectExportService();
      for (final imageData in images) {
        final project = original.copyWith(
          pages: [
            page.copyWith(
              graphics: [sourceImage.copyWith(imageData: imageData)],
            ),
          ],
        );
        final bytes = await exporter.pdf(project);
        expect(latin1.decode(bytes), contains('/Subtype/Image'));
        expect(project.pages.single.graphics.single.imageData, imageData);
        expect(exporter.svg(project), contains('base64,$imageData'));
      }
    },
  );
}
