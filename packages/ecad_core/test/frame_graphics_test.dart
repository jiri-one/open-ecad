// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:ecad_core/ecad_core.dart';
import 'package:test/test.dart';

const _pixel =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jf2cAAAAASUVORK5CYII=';
Sheet _sheet(List<DrawingElement> graphics) => Sheet(
  id: 's',
  name: 'Artwork',
  number: '1',
  graphics: graphics,
  frame: const FrameChoice.none(),
);
FrameGeometry _frame(Sheet sheet) => layoutFrameGeometry(
  sheet.paperSizeMm,
  ResolvedFrame(FrameTemplates.builtin),
);
DrawingElement _path() => DrawingElement(
  id: 'path',
  kind: DrawingKind.path,
  position: const Vec2(20, 30),
  width: 160,
  height: 80,
  rotation: 37,
  stroke: '#123456',
  strokeWidth: 2,
  dash: [3, 5],
  opacity: 0.7,
  lineJoin: 2,
  path: [
    PathSegment(verb: PathVerb.moveTo, points: [Vec2.zero]),
    PathSegment(
      verb: PathVerb.cubicTo,
      points: [const Vec2(-20, 90), const Vec2(140, -40), const Vec2(160, 80)],
    ),
  ],
);

void main() {
  test(
    'selected remaining artwork fits uniformly with IDs/order/rotation and vector payload intact',
    () {
      final oldFrame = DrawingElement(
        id: 'oldFrame',
        kind: DrawingKind.text,
        position: const Vec2(-10000, -10000),
        width: 20000,
        height: 20000,
        text: 'Old title',
      );
      final source = _sheet([
        oldFrame,
        _path(),
        DrawingElement(
          id: 'text',
          kind: DrawingKind.text,
          position: const Vec2(200, 40),
          width: 60,
          height: 12,
          text: 'Řídicí\nobvod',
          fontSize: 9,
          rotation: 90,
          bold: true,
          fill: '#000000',
        ),
        DrawingElement(
          id: 'image',
          kind: DrawingKind.image,
          position: const Vec2(150, 160),
          width: 35,
          height: 25,
          imageData: _pixel,
          rotation: 270,
        ),
      ]);
      final target = source.copyWith(
        paperSizeMm: SizeMm.a4Landscape,
        width: 1000,
        height: 800,
        frame: const FrameChoice.inherit(),
      );
      final geometry = _frame(target);
      final fitted = fitGraphicsToFrame(
        source,
        target,
        geometry,
        retainedGraphicIds: {'path', 'text', 'image'},
      );
      expect(fitted.map((g) => g.id), ['path', 'text', 'image']);
      expect(source.graphics.first, same(oldFrame));
      final scale = fitted[1].fontSize / 9;
      expect(scale, greaterThan(1));
      final offset =
          fitted.first.position - source.graphics[1].position * scale;
      final bounds = frameContentUnits(target, geometry);
      for (var i = 0; i < fitted.length; i++) {
        final original = source.graphics[i + 1], next = fitted[i];
        requireValidDrawingElement(next);
        expect(next.rotation, original.rotation);
        expect(next.width, closeTo(original.width * scale, 1e-9));
        expect(next.height, closeTo(original.height * scale, 1e-9));
        expect(next.strokeWidth, closeTo(original.strokeWidth * scale, 1e-9));
        expect(next.text, original.text);
        expect(next.imageData, original.imageData);
        expect(next.opacity, original.opacity);
        expect(next.lineJoin, original.lineJoin);
        final points =
            original.kind == DrawingKind.path
                ? original.path.expand((s) => s.points)
                : [
                  Vec2.zero,
                  Vec2(original.width, 0),
                  Vec2(original.width, original.height),
                  Vec2(0, original.height),
                ];
        final nextPoints =
            next.kind == DrawingKind.path
                ? next.path.expand((s) => s.points).toList()
                : [
                  Vec2.zero,
                  Vec2(next.width, 0),
                  Vec2(next.width, next.height),
                  Vec2(0, next.height),
                ];
        for (final (index, local) in points.indexed) {
          final expected =
              (original.position + local.rotated(original.rotation)) * scale +
              offset;
          final actual =
              next.position + nextPoints[index].rotated(next.rotation);
          expect(actual.x, closeTo(expected.x, 1e-9));
          expect(actual.y, closeTo(expected.y, 1e-9));
          expect(
            actual.x,
            inInclusiveRange(bounds.x - 1e-9, bounds.x + bounds.width + 1e-9),
          );
          expect(
            actual.y,
            inInclusiveRange(bounds.y - 1e-9, bounds.y + bounds.height + 1e-9),
          );
        }
      }
      expect(fitted.first.dash[0], closeTo(3 * scale, 1e-9));
      expect(fitted.first.dash[1], closeTo(5 * scale, 1e-9));
      final withOld = fitGraphicsToFrame(
        source,
        target,
        geometry,
        retainedGraphicIds: source.graphics.map((g) => g.id).toSet(),
      );
      expect(withOld, hasLength(4));
      expect(withOld[2].fontSize, lessThan(fitted[1].fontSize));
    },
  );

  test(
    'empty selection and point-only content are finite and do not invent objects',
    () {
      final source = _sheet([_path()]);
      expect(
        fitGraphicsToFrame(
          source,
          source,
          _frame(source),
          retainedGraphicIds: {},
        ),
        isEmpty,
      );
      final point = _sheet([
        DrawingElement(
          id: 'p',
          kind: DrawingKind.path,
          position: Vec2.zero,
          width: 0,
          height: 0,
          path: [
            PathSegment(verb: PathVerb.moveTo, points: [const Vec2(5, 8)]),
          ],
        ),
      ]);
      final fitted =
          fitGraphicsToFrame(
            point,
            point,
            _frame(point),
            retainedGraphicIds: {'p'},
          ).single;
      expect(fitted.id, 'p');
      expect(fitted.position.x.isFinite, isTrue);
      expect(fitted.path.single.points.single, const Vec2(5, 8));
      expect(
        fitGraphicsToFrame(
          _sheet([]),
          _sheet([]),
          _frame(source),
          retainedGraphicIds: {},
        ),
        isEmpty,
      );
    },
  );

  test(
    'fitting rejects stale selection, duplicate IDs, semantic sheets and bad transforms',
    () {
      final source = _sheet([_path()]);
      expect(
        () => fitGraphicsToFrame(
          source,
          source,
          _frame(source),
          retainedGraphicIds: {'missing'},
        ),
        throwsA(isA<EcadException>()),
      );
      final duplicate = _sheet([_path(), _path()]);
      expect(
        () => fitGraphicsToFrame(
          duplicate,
          source,
          _frame(source),
          retainedGraphicIds: {'path'},
        ),
        throwsA(isA<EcadException>()),
      );
      for (final sheet in [
        source.copyWith(
          type: SheetType.cabinetLayout,
          sourcePage: 1,
          mountingView: const MountingView(
            layoutId: 'layout',
            viewport: RectUnits(x: 10, y: 10, width: 500, height: 400),
          ),
        ),
        source.copyWith(type: SheetType.billOfMaterials),
        source.copyWith(
          corners: [const ConnectionCorner(id: 'c', position: Vec2.zero)],
        ),
        source.copyWith(
          report: const BomTableSpec(kind: BomReportKind.articles),
        ),
      ]) {
        expect(
          () => fitGraphicsToFrame(
            sheet,
            source,
            _frame(source),
            retainedGraphicIds: {'path'},
          ),
          throwsA(isA<EcadException>()),
        );
        expect(
          () => fitGraphicsToFrame(
            source,
            sheet,
            _frame(source),
            retainedGraphicIds: {'path'},
          ),
          throwsA(isA<EcadException>()),
        );
      }
      for (final scale in [0.0, -1.0, double.infinity, double.nan]) {
        expect(
          () => transformGraphic(_path(), scale: scale, offset: Vec2.zero),
          throwsA(isA<EcadException>()),
        );
      }
    },
  );

  test(
    'new blank forms use bounds without rewriting existing graphics on frame changes',
    () {
      final sheet = _sheet([]).copyWith(
        frame: const FrameChoice.inherit(),
        paperSizeMm: SizeMm.a4Landscape,
      );
      final geometry = _frame(sheet);
      final content = frameContentUnits(sheet, geometry);
      final graphics = SheetTemplates.blankForm(contentBounds: content);
      for (final graphic in graphics) {
        requireValidDrawingElement(graphic);
        final pad = graphic.stroke == null ? 0 : graphic.strokeWidth / 2;
        expect(graphic.position.x - pad, greaterThanOrEqualTo(content.x));
        expect(graphic.position.y - pad, greaterThanOrEqualTo(content.y));
        expect(
          graphic.position.x + graphic.width + pad,
          lessThanOrEqualTo(content.x + content.width),
        );
        expect(
          graphic.position.y + graphic.height + pad,
          lessThanOrEqualTo(content.y + content.height),
        );
      }
      final engine = ProjectEngine(
        EcadProject(
          id: 'project',
          name: 'Project',
          pages: [sheet.copyWith(graphics: graphics)],
        ),
      );
      final before =
          engine.project.pages.single.graphics.map((g) => g.toJson()).toList();
      engine.execute([
        const SetSheetFrame('s', FrameChoice.none()),
        UpdateFrameTemplate(
          FrameTemplates.builtin.copyWith(contentPaddingMm: 20),
        ),
      ]);
      expect(
        engine.project.pages.single.graphics.map((g) => g.toJson()).toList(),
        before,
      );
      final caption = graphics.firstWhere((g) => g.kind == DrawingKind.text);
      final standard = SheetTemplates.blankForm().firstWhere(
        (g) => g.kind == DrawingKind.text,
      );
      expect(
        caption.width / caption.fontSize,
        closeTo(standard.width / standard.fontSize, 1e-9),
      );
      expect(
        () => SheetTemplates.blankForm(
          contentBounds: const RectUnits(x: 0, y: 0, width: 0, height: 4),
        ),
        throwsA(isA<EcadException>()),
      );
    },
  );
}
